# Enabling Encryption at Rest with Harvester

This repo will cover the various cases of encryption at rest presented by the hyperconverged infrastructure product from SUSE Rancher named [Harvester](https://docs.harvesterhci.io/v1.2/).

## Introduction
Harvester leverages several open-source projects to provide hyperconverged infrastructure services. As we are focusing specifically on encryption at rest, I will focus upon the storage mechanism named [Longhorn](https://longhorn.io/docs/1.5.1/).

While Harvester does include Longhorn to manage all storage, it does not expose all configuration options to the user. This is done for stability reasons in that Harvester is built/tested with Longhorn used in a specific fashion. Stepping outside of that can cause issues that make supporting a product difficult.

One of those features not completely exposed as of `v1.2.1` is encryption at rest with Longhorn.

## Longhorn and Encryption at Rest

Longhorn has the capability of doing encryption at rest both globally and on a per volume level. The keys for encryption are stored in the longhorn namespace and mapped to new `StorageClass` objects that specify the encryption enable flags as well as the reference to the `Secret` object containing the symmetric key.

A brief introduction can be seen on the [Longhorn documentation page](https://longhorn.io/docs/1.5.1/advanced-resources/security/volume-encryption/)

## Differences with Harvester
While Harvester does include Longhorn storage classes, it also has to handle the case of virtual machine images for each VM. If I create a VM image to make available for VM creation, under the hood Harvester is creating a new StorageClass based on a backing baseline image. When I create the VM, the root filesystem uses this storage class for its volume type and the resulting PVC that gets created is a copy of the backing image.

The K8S CRD defining these VM images is a `VirtualMachineImage` and it contains within it a set of configuration options to feed into the resulting storage class that gets created. I can manually create a VMI from the K8S API and feed these config options manually. What should happen is those options eventually make it to the resulting `StorageClass` object that gets created, but that is not the case. The object as specified does not make it to etcd and appears to be stripped out.

## Capabilities as of 1.2.1

Where does this leave us? Encryption at Rest does work in Longhorn and is exposed as a `StorageClass` option, but VM images due to their multi-step process does not allow for this. Given that VMs can also include additional volumes based on direct storage classes, we should also be able to encrypt additional volumes.

Current capabilities:
* Encryption works for Containerized volumes (classic PVC in a K8S cluster)
* Encrytion works for additional VM volumes
* Encryption does NOT work for root filesystems for VMs

### Pre-Steps

WARNING: I am using a single Harvester node for this test, so volumes will highlight in yellow within the Longhorn UI as they do not have sufficient replica count to be counted as healthy (3).

Before testing any encryption capabilities, I need to create an [encryption key and configured storage class](yaml/encryption_enable.yaml). I will use the global key example from the longhorn docs.
```console
> kc apply -f yaml/encryption_enable.yaml
secret/longhorn-crypto created
storageclass.storage.k8s.io/longhorn-crypto-global created
```

### Encryption of Containerized Volumes
For proving that Harvester is capable of encrypting PVCs, I use an example [Block Volume object](yaml/pvc_test.yaml) and ensure the `StorageClass` referenced is the one I created in the previous step.
```console
> kc apply -f yaml/pvc_test.yaml
persistentvolumeclaim/test created
```

Unlike the `StorageClass` and key, I can visually confirm this object is created in the UI

![volume](images/volume-add.png)

And I can confirm within Longhorn that this PVC encrypted

![volume-longhorn](images/volume-add-longhorn.png)

This object is a block storage type but the process and example is identical for container, I just need a different PVC created
```console
> kc apply -f yaml/pvc_test_container.yaml
persistentvolumeclaim/test-container created
```

Instead of using the Harvester UI I can verify via the embedded Rancher UI that this volume is running:

![volume-ext4](images/volume-add-ext4.png)

Again I can view this in the Longhorn UI as well:

![volume-ext4-longhorn](images/volume-add-ext4-longhorn.png)


### Encryption of Additional Volumes
For the additional volume case, I can spin up a VM instance and add an additional volume to it.

First I'll create an Ubuntu-20.04 base image using the upstream Canoncial cloud image:
```console
> kc apply -f vmi.yaml
virtualmachineimage.harvesterhci.io/ubuntu-2004 created
```

I can verify this image exists via the Harvester UI:

![vmi-base](images/vmi-base.png)

Now I can create a VM based on this root image and go to the Volume section and add the block volume I created earlier:

![vm-volume-create](images/vm-volume-create.png)

Once I click `Create` the VM base image storage class will be used to create the root filesystem for the VM and the additional volume will also be mounted.

![vm-created](images/vm-created.png)

I can verify the volumes have attached via the Longhorn UI. The first volume is unencrypted and is the root filesystem. The third in the list is the second volume and is encrypted.

![vm-created-longhorn](images/vm-volume-attached.png)

### Encryption failing for VM root filesystems

The last case does not work but required a bit of analysis of the `VirtualMachineImage` object mentioned earlier. Within the [VMI](yaml/vmi.yaml) we can see a few fields that are implicitly passed to the resulting `StorageClass` created as a result of the VMI object being created.

```yaml
spec:
  storageClassParameters:
    migratable: 'true'
    numberOfReplicas: '3'
    staleReplicaTimeout: '30'
```

I'm going to attempt to create a [new VM image](yaml/vmi-encrypted.yaml) and place the same paramters added to the `longhorn-crypto-global` storage class created earlier. The result is below:

```yaml
spec:
  storageClassParameters:
    migratable: 'true'
    numberOfReplicas: '3'
    staleReplicaTimeout: '30'
    encrypted: "true"
    csi.storage.k8s.io/provisioner-secret-name: "longhorn-crypto"
    csi.storage.k8s.io/provisioner-secret-namespace: "longhorn-system"
    csi.storage.k8s.io/node-publish-secret-name: "longhorn-crypto"
    csi.storage.k8s.io/node-publish-secret-namespace: "longhorn-system"
    csi.storage.k8s.io/node-stage-secret-name: "longhorn-crypto"
    csi.storage.k8s.io/node-stage-secret-namespace: "longhorn-system"
```

Here's the result of creation:

```console
> kc apply -f yaml/vmi-encrypted.yaml
virtualmachineimage.harvesterhci.io/ubuntu-2004-encrypted created
> kc get virtualmachineimage
NAME                    DISPLAY-NAME            SIZE        AGE
ubuntu-2004             ubuntu-2004             641400832   31m
ubuntu-2004-encrypted   ubuntu-2004-encrypted   641400832   61s
```

While the image created successfully, when I peer into the `StorageClass` that gets created as a result of this process, I can see the parameters I passed to it were dropped:

```console
> kc get storageclass
NAME                             PROVISIONER          RECLAIMPOLICY   VOLUMEBINDINGMODE   ALLOWVOLUMEEXPANSION   AGE
harvester-longhorn (default)     driver.longhorn.io   Delete          Immediate           true                   19h
longhorn                         driver.longhorn.io   Delete          Immediate           true                   19h
longhorn-crypto-global           driver.longhorn.io   Delete          Immediate           true                   40m
longhorn-ubuntu-2004             driver.longhorn.io   Delete          Immediate           true                   32m
longhorn-ubuntu-2004-encrypted   driver.longhorn.io   Delete          Immediate           true                   2m34s
> kc get storageclass longhorn-ubuntu-2004-encrypted -o yaml
allowVolumeExpansion: true
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  creationTimestamp: "2023-11-02T13:08:50Z"
  name: longhorn-ubuntu-2004-encrypted
  resourceVersion: "997696"
  uid: 69232a34-992a-4b94-96a2-091b2f18d175
parameters:
  backingImage: default-ubuntu-2004-encrypted
  migratable: "true"
  numberOfReplicas: "3"
  staleReplicaTimeout: "30"
provisioner: driver.longhorn.io
reclaimPolicy: Delete
volumeBindingMode: Immediate
```

If we look at the one we created in the pre-step for comparison, specifically the parameter field, we can see what we expected (and that is not there):

```console
> kc get storageclass longhorn-crypto-global -o yaml | yq .parameters
csi.storage.k8s.io/node-publish-secret-name: longhorn-crypto
csi.storage.k8s.io/node-publish-secret-namespace: longhorn-system
csi.storage.k8s.io/node-stage-secret-name: longhorn-crypto
csi.storage.k8s.io/node-stage-secret-namespace: longhorn-system
csi.storage.k8s.io/provisioner-secret-name: longhorn-crypto
csi.storage.k8s.io/provisioner-secret-namespace: longhorn-system
encrypted: "true"
fromBackup: ""
numberOfReplicas: "3"
staleReplicaTimeout: "2880"
```

When using this storageclass either manually via volume creation, or by creating a VM instance, the volume created does not show to be encrypted:

![vm-create-fail](images/vm-created-encrypted-fail.png)

And Longhorn UI:

![vm-create-fail-longhorn](images/vm-created-encrypted-fail-longhorn.png)

### Hacking the Gibson

Unfortunately, the process would normally stop here. While the easy answer would be modifying the `StorageClass` object itself, they are immutable by their nature making that impossible. 

However, that does not prevent us from cloning it to use the same backing image. I've copied the resulting storage class and [modified it](yaml/storageclass_hack.yaml) so I can create a new one.

The trouble with just cloning it is that Harvester ALSO needs a VMI image to tie the VM to the storage class, think of it as a binding class. Given that, there's no reason we can't just DELETE the old `StorageClass` and replace it.

```console
> kc delete sc longhorn-ubuntu-2004-encrypted
storageclass.storage.k8s.io "longhorn-ubuntu-2004-encrypted" deleted
> kc apply -f yaml/storageclass_hack.yaml
storageclass.storage.k8s.io/longhorn-ubuntu-2004-encrypted created
```

So far so good. Nothing is amiss in the VM Images upon inspection. I'll now create a new VM using this VMI.

![vm-created-hack](images/vm-created-hack.png)

The VM created successfully using the encryption-enabled `StorageClass`. Now inspecting the Longhorn UI we can see the root volume is encrypted!!! Our tweak was successful!

![vm-created-hack-longhorn](images/vm-created-hack-longhorn.png)

# Requests

From a customer perspective, the final product for this feature does need to have some UI elements. But if there are no major blockers, just enabling the passing of the `storageClassParameters` field to enable encryption within Longhorn for the VM root volume would be an amazing feature even if listed as experimental. 

It does appear based on the hack above that passing the parameters properly from VMI to SC will 'just work'.

# Performance Testing
One of the consequences of encryption is a performance penalty. Using the discovered information above, we can now test what that penalty looks like in Harvester. Keep in mind that the Harvester case is utilizing Longhorn on bare metal with VMs and thus has a significantly higher performance than the typically virtualized Longhorn-on-RKE2 implementation.

Using the 'hack' above, I will force encryption on a new image and run a variety of tests and report them below. There will be a corresponding image created without the encryption and run with the same VM specs on the same node to keep things even.

## VM Specs
For the VMs I want to ensure the encryption is not compute/memory bound so I will keep those high and consistent between both VMs. Each VM will also run independently while the other is shut down.
Specs:
* Ubuntu 20.04 LTS VM image
* 8 cores, 32gb memory
* 120gb of storage
* NVME drives (Samsung 990 Pro 1TB)
* Harvester 1.2.1

## Tests
The IO tests I will be using are as follows as suggested from [this page](https://linuxreviews.org/HOWTO_Test_Disk_I/O_Performance).

* hdparm
* dd
* fio - sequential read
* fio - sequential write
* fio - random reads
* fio - random reads/writes
* bonnie++

## Steps for Test

Enable Encryption:
```console
> kubectl apply -f yaml/encryption_enable.yaml
secret/longhorn-crypto created
storageclass.storage.k8s.io/longhorn-crypto-global created
```

Create VMIs:
> kubectl apply -f yaml/vmi.yaml
virtualmachineimage.harvesterhci.io/ubuntu-2004 created
> kubectl apply -f yaml/vmi-encrypted.yaml
virtualmachineimage.harvesterhci.io/ubuntu-2004-encrypted created
> kubectl get virtualmachineimage
NAME                    DISPLAY-NAME            SIZE        AGE
ubuntu-2004             ubuntu-2004             641400832   31m
ubuntu-2004-encrypted   ubuntu-2004-encrypted   641400832   61s
```

Hack the encrypted storage class by hot-swapping it:
```console
> kubectl delete sc longhorn-ubuntu-2004-encrypted
storageclass.storage.k8s.io "longhorn-ubuntu-2004-encrypted" deleted
> kubectl apply -f yaml/storageclass_hack.yaml
storageclass.storage.k8s.io/longhorn-ubuntu-2004-encrypted created
```

## Performing Tests
I'll begin by spinning up a VM based on the unencrypted VMI and set it to the specifications I stated above.

The `fio` app needs installing, so I install that first with `sudo apt install fio`.
The `bonnie++` app can be installed using `sudo apt install bonnie++`.

My disk device appears to be mounted as `/dev/vda` according to my check:
```console
ubuntu@unencrypted-test:~$ df
Filesystem     1K-blocks    Used Available Use% Mounted on
udev            16366844       0  16366844   0% /dev
tmpfs            3276848    1152   3275696   1% /run
/dev/vda1       60782776 1748680  59017712   3% /
tmpfs           16384228       0  16384228   0% /dev/shm
tmpfs               5120       0      5120   0% /run/lock
tmpfs           16384228       0  16384228   0% /sys/fs/cgroup
/dev/loop0         65024   65024         0 100% /snap/core20/2015
/dev/loop1         41856   41856         0 100% /snap/snapd/20290
/dev/loop2         94080   94080         0 100% /snap/lxd/24061
/dev/vda15        106858    6186    100673   6% /boot/efi
tmpfs            3276844       0   3276844   0% /run/user/1000
```

Running `hdparm` test uses `sudo hdparm --direct -t -T /dev/vda`

Running `dd` test uses `sudo dd if=/dev/zero of=test.file bs=64M count=16 oflag=dsync`

`fio` sequential read: `sudo fio --name TEST --eta-newline=5s --filename=temp.file --rw=read --size=2g --io_size=10g --blocksize=1024k --ioengine=libaio --fsync=10000 --iodepth=32 --direct=1 --numjobs=1 --runtime=60 --group_reporting`

`fio` sequential write: `sudo fio --name TEST --eta-newline=5s --filename=temp.file --rw=write --size=2g --io_size=10g --blocksize=1024k --ioengine=libaio --fsync=10000 --iodepth=32 --direct=1 --numjobs=1 --runtime=60 --group_reporting`

`fio` random reads: `sudo fio --name TEST --eta-newline=5s --filename=temp.file --rw=randread --size=2g --io_size=10g --blocksize=4k --ioengine=libaio --fsync=1 --iodepth=1 --direct=1 --numjobs=32 --runtime=60 --group_reporting`

`fio` random reads/writes: `sudo fio --name TEST --eta-newline=5s --filename=temp.file --rw=randrw --size=2g --io_size=10g --blocksize=4k --ioengine=libaio --fsync=1 --iodepth=1 --direct=1 --numjobs=1 --runtime=60 --group_reporting`


## Results
### TL;DR
One would expect unencrypted is just going to perform better due to the overhead but it appears that decryption happens when the VM is started (much like normal OS encryption-at-rest). So there does not appear to be any performance penalty. Any VM start/stop latency difference was not measured but due to variance between start/stops normally, it would likely be a wash in difference.

* `hdparm`
  * Cache Reads: 271.85 MB/sec vs 266.99 MB/sec equals 1.79% reduction
* `dd`
  * Block Copy/Write: 126 MB/sec vs 125 MB/sec equals 0.79% reduction
* `fio`
  * seq read: 260MiB/s vs 309MiB/s equal 18% increase (this is likely due to random outlier test)
  * seq write: 134MiB/s vs 134MiB/s equals no difference
  * random read: 159MiB/s vs 159MiB/s equals no difference
  * random read/write: 1124KiB/s read, 1123KiB/s write and 1156KiB/s read, 1155KiB/s KiB/s write, equals 2.85% and 2.93% increase (this is likely due to random outlier test)

### Unencrypted
`hdparm` results
* cached reads: 271.85 MB/sec
* disk reads: 174.56 MB/sec

```console
ubuntu@unencrypted-test:~$ sudo hdparm --direct -t -T /dev/vda

/dev/vda:
 Timing O_DIRECT cached reads:   544 MB in  2.00 seconds = 271.85 MB/sec
 HDIO_DRIVE_CMD(identify) failed: Inappropriate ioctl for device
 Timing O_DIRECT disk reads: 524 MB in  3.00 seconds = 174.56 MB/sec
```

`dd` results:
*  (1.1 GB, 1.0 GiB) copied, 8.5209 s, 126 MB/s

```console
ubuntu@unencrypted-test:~$ sudo dd if=/dev/zero of=test.file bs=64M count=16 oflag=dsync
16+0 records in
16+0 records out
1073741824 bytes (1.1 GB, 1.0 GiB) copied, 8.5209 s, 126 MB/s
```

`fio` results:
* sequential read: READ: bw=271MiB/s (285MB/s), 271MiB/s-271MiB/s (285MB/s-285MB/s), io=10.0GiB (10.7GB), run=37737-37737msec
* sequential write: WRITE: bw=134MiB/s (140MB/s), 134MiB/s-134MiB/s (140MB/s-140MB/s), io=8067MiB (8459MB), run=60237-60237msec
* random read: READ: bw=159MiB/s (167MB/s), 159MiB/s-159MiB/s (167MB/s-167MB/s), io=9527MiB (9990MB), run=60001-60001msec
* random reads/writes:
  * READ: bw=1156KiB/s (1183kB/s), 1156KiB/s-1156KiB/s (1183kB/s-1183kB/s), io=67.7MiB (70.0MB), run=60001-60001msec
  * WRITE: bw=1155KiB/s (1182kB/s), 1155KiB/s-1155KiB/s (1182kB/s-1182kB/s), io=67.7MiB (70.9MB), run=60001-60001msec

sequential read:
```console
ubuntu@unencrypted-test:~$ sudo fio --name TEST --eta-newline=5s --filename=temp.file --rw=read --size=2g --io_size=10g --blocksize=1024k --ioengine=libaio --fsync=10000 --iodepth=32 --direct=1 --numjobs=1 --runtime=60 --group_reporting
TEST: (g=0): rw=read, bs=(R) 1024KiB-1024KiB, (W) 1024KiB-1024KiB, (T) 1024KiB-1024KiB, ioengine=libaio, iodepth=32
fio-3.16
Starting 1 process
TEST: Laying out IO file (1 file / 2048MiB)
Jobs: 1 (f=1): [R(1)][20.0%][r=191MiB/s][r=191 IOPS][eta 00m:32s]
Jobs: 1 (f=1): [R(1)][35.9%][r=112MiB/s][r=112 IOPS][eta 00m:25s] 
Jobs: 1 (f=1): [R(1)][52.6%][r=82.0MiB/s][r=82 IOPS][eta 00m:18s] 
Jobs: 1 (f=1): [R(1)][66.7%][r=358MiB/s][r=358 IOPS][eta 00m:13s] 
Jobs: 1 (f=1): [R(1)][80.0%][r=32.0MiB/s][r=32 IOPS][eta 00m:08s] 
Jobs: 1 (f=1): [R(1)][100.0%][r=376MiB/s][r=376 IOPS][eta 00m:00s]
TEST: (groupid=0, jobs=1): err= 0: pid=2875: Tue Dec 19 20:40:21 2023
  read: IOPS=271, BW=271MiB/s (285MB/s)(10.0GiB/37737msec)
    slat (usec): min=12, max=485, avg=47.77, stdev=20.93
    clat (msec): min=4, max=890, avg=117.81, stdev=144.20
     lat (msec): min=4, max=891, avg=117.86, stdev=144.20
    clat percentiles (msec):
     |  1.00th=[    8],  5.00th=[   25], 10.00th=[   40], 20.00th=[   42],
     | 30.00th=[   45], 40.00th=[   89], 50.00th=[   93], 60.00th=[   96],
     | 70.00th=[  101], 80.00th=[  107], 90.00th=[  236], 95.00th=[  634],
     | 99.00th=[  709], 99.50th=[  726], 99.90th=[  860], 99.95th=[  869],
     | 99.99th=[  885]
   bw (  KiB/s): min=53248, max=450560, per=100.00%, avg=288719.39, stdev=128823.69, samples=72
   iops        : min=   52, max=  440, avg=281.94, stdev=125.80, samples=72
  lat (msec)   : 10=1.75%, 20=2.42%, 50=28.10%, 100=38.40%, 250=20.44%
  lat (msec)   : 500=3.58%, 750=5.19%, 1000=0.13%
  cpu          : usr=0.34%, sys=1.64%, ctx=9975, majf=0, minf=8204
  IO depths    : 1=0.1%, 2=0.1%, 4=0.2%, 8=0.4%, 16=0.8%, 32=98.5%, >=64=0.0%
     submit    : 0=0.0%, 4=100.0%, 8=0.0%, 16=0.0%, 32=0.0%, 64=0.0%, >=64=0.0%
     complete  : 0=0.0%, 4=100.0%, 8=0.0%, 16=0.0%, 32=0.1%, 64=0.0%, >=64=0.0%
     issued rwts: total=10240,0,0,0 short=0,0,0,0 dropped=0,0,0,0
     latency   : target=0, window=0, percentile=100.00%, depth=32

Run status group 0 (all jobs):
   READ: bw=271MiB/s (285MB/s), 271MiB/s-271MiB/s (285MB/s-285MB/s), io=10.0GiB (10.7GB), run=37737-37737msec

Disk stats (read/write):
  vda: ios=10547/85, merge=0/24, ticks=1234455/20580, in_queue=1234276, util=91.14%
```

sequential write:

```console
ubuntu@unencrypted-test:~$ sudo fio --name TEST --eta-newline=5s --filename=temp.file --rw=write --size=2g --io_size=10g --blocksize=1024k --ioengine=libaio --fsync=10000 --iodepth=32 --direct=1 --numjobs=1 --runtime=60 --group_reporting
TEST: (g=0): rw=write, bs=(R) 1024KiB-1024KiB, (W) 1024KiB-1024KiB, (T) 1024KiB-1024KiB, ioengine=libaio, iodepth=32
fio-3.16
Starting 1 process
Jobs: 1 (f=1): [W(1)][11.7%][w=134MiB/s][w=134 IOPS][eta 00m:53s]
Jobs: 1 (f=1): [W(1)][21.7%][w=135MiB/s][w=135 IOPS][eta 00m:47s] 
Jobs: 1 (f=1): [W(1)][31.7%][w=142MiB/s][w=142 IOPS][eta 00m:41s] 
Jobs: 1 (f=1): [W(1)][41.7%][w=118MiB/s][w=118 IOPS][eta 00m:35s] 
Jobs: 1 (f=1): [W(1)][51.7%][w=145MiB/s][w=145 IOPS][eta 00m:29s] 
Jobs: 1 (f=1): [W(1)][61.7%][w=135MiB/s][w=135 IOPS][eta 00m:23s] 
Jobs: 1 (f=1): [W(1)][71.7%][w=135MiB/s][w=135 IOPS][eta 00m:17s] 
Jobs: 1 (f=1): [W(1)][81.7%][w=133MiB/s][w=133 IOPS][eta 00m:11s] 
Jobs: 1 (f=1): [W(1)][91.7%][w=124MiB/s][w=124 IOPS][eta 00m:05s] 
Jobs: 1 (f=1): [W(1)][100.0%][w=125MiB/s][w=125 IOPS][eta 00m:00s]
TEST: (groupid=0, jobs=1): err= 0: pid=3460: Tue Dec 19 17:59:34 2023
  write: IOPS=133, BW=134MiB/s (140MB/s)(8067MiB/60237msec); 0 zone resets
    slat (usec): min=16, max=190839, avg=352.10, stdev=6908.70
    clat (msec): min=18, max=443, avg=238.48, stdev=32.58
     lat (msec): min=23, max=443, avg=238.83, stdev=31.61
    clat percentiles (msec):
     |  1.00th=[   99],  5.00th=[  215], 10.00th=[  232], 20.00th=[  234],
     | 30.00th=[  236], 40.00th=[  236], 50.00th=[  236], 60.00th=[  239],
     | 70.00th=[  239], 80.00th=[  241], 90.00th=[  251], 95.00th=[  279],
     | 99.00th=[  380], 99.50th=[  393], 99.90th=[  409], 99.95th=[  422],
     | 99.99th=[  443]
   bw (  KiB/s): min=96256, max=159744, per=99.98%, avg=137110.27, stdev=6784.08, samples=120
   iops        : min=   94, max=  156, avg=133.84, stdev= 6.64, samples=120
  lat (msec)   : 20=0.02%, 50=0.26%, 100=0.74%, 250=88.78%, 500=10.19%
  cpu          : usr=0.72%, sys=0.88%, ctx=7469, majf=0, minf=12
  IO depths    : 1=0.1%, 2=0.1%, 4=0.2%, 8=0.4%, 16=0.8%, 32=98.5%, >=64=0.0%
     submit    : 0=0.0%, 4=100.0%, 8=0.0%, 16=0.0%, 32=0.0%, 64=0.0%, >=64=0.0%
     complete  : 0=0.0%, 4=99.9%, 8=0.0%, 16=0.0%, 32=0.1%, 64=0.0%, >=64=0.0%
     issued rwts: total=0,8067,0,0 short=0,0,0,0 dropped=0,0,0,0
     latency   : target=0, window=0, percentile=100.00%, depth=32

Run status group 0 (all jobs):
  WRITE: bw=134MiB/s (140MB/s), 134MiB/s-134MiB/s (140MB/s-140MB/s), io=8067MiB (8459MB), run=60237-60237msec

Disk stats (read/write):
  vda: ios=0/8349, merge=0/15, ticks=0/1944700, in_queue=1928292, util=99.81%
```

random read:

```console
ubuntu@unencrypted-test:~$ sudo fio --name TEST --eta-newline=5s --filename=temp.file --rw=randread --size=2g --io_size=10g --blocksize=4k --ioengine=libaio --fsync=1 --iodepth=1 --direct=1 --numjobs=32 --runtime=60 --group_reporting
TEST: (g=0): rw=randread, bs=(R) 4096B-4096B, (W) 4096B-4096B, (T) 4096B-4096B, ioengine=libaio, iodepth=1
...
fio-3.16
Starting 32 processes
Jobs: 32 (f=32): [r(32)][11.7%][r=166MiB/s][r=42.5k IOPS][eta 00m:53s]
Jobs: 32 (f=32): [r(32)][21.7%][r=158MiB/s][r=40.5k IOPS][eta 00m:47s] 
Jobs: 32 (f=32): [r(32)][31.7%][r=159MiB/s][r=40.7k IOPS][eta 00m:41s] 
Jobs: 32 (f=32): [r(32)][41.7%][r=163MiB/s][r=41.8k IOPS][eta 00m:35s] 
Jobs: 32 (f=32): [r(32)][51.7%][r=160MiB/s][r=40.9k IOPS][eta 00m:29s] 
Jobs: 32 (f=32): [r(32)][61.7%][r=162MiB/s][r=41.4k IOPS][eta 00m:23s] 
Jobs: 32 (f=32): [r(32)][71.7%][r=160MiB/s][r=41.0k IOPS][eta 00m:17s] 
Jobs: 32 (f=32): [r(32)][81.7%][r=152MiB/s][r=39.0k IOPS][eta 00m:11s] 
Jobs: 32 (f=32): [r(32)][91.7%][r=161MiB/s][r=41.1k IOPS][eta 00m:05s] 
Jobs: 32 (f=32): [r(32)][100.0%][r=162MiB/s][r=41.4k IOPS][eta 00m:00s]
TEST: (groupid=0, jobs=32): err= 0: pid=3468: Tue Dec 19 18:09:58 2023
  read: IOPS=40.6k, BW=159MiB/s (167MB/s)(9527MiB/60001msec)
    slat (nsec): min=1312, max=2598.1k, avg=7747.35, stdev=13633.68
    clat (nsec): min=391, max=20627k, avg=777936.56, stdev=343659.04
     lat (usec): min=203, max=20632, avg=785.83, stdev=343.69
    clat percentiles (usec):
     |  1.00th=[  408],  5.00th=[  490], 10.00th=[  537], 20.00th=[  594],
     | 30.00th=[  644], 40.00th=[  685], 50.00th=[  717], 60.00th=[  758],
     | 70.00th=[  807], 80.00th=[  873], 90.00th=[ 1037], 95.00th=[ 1254],
     | 99.00th=[ 2073], 99.50th=[ 2606], 99.90th=[ 4146], 99.95th=[ 5014],
     | 99.99th=[ 9896]
   bw (  KiB/s): min=120320, max=177048, per=99.99%, avg=162573.86, stdev=247.93, samples=3812
   iops        : min=30080, max=44262, avg=40642.84, stdev=61.99, samples=3812
  lat (nsec)   : 500=0.01%, 750=0.01%, 1000=0.01%
  lat (usec)   : 2=0.01%, 4=0.01%, 10=0.01%, 50=0.01%, 100=0.01%
  lat (usec)   : 250=0.01%, 500=6.01%, 750=51.86%, 1000=30.65%
  lat (msec)   : 2=10.37%, 4=0.99%, 10=0.10%, 20=0.01%, 50=0.01%
  cpu          : usr=0.31%, sys=2.21%, ctx=2439116, majf=0, minf=397
  IO depths    : 1=100.0%, 2=0.0%, 4=0.0%, 8=0.0%, 16=0.0%, 32=0.0%, >=64=0.0%
     submit    : 0=0.0%, 4=100.0%, 8=0.0%, 16=0.0%, 32=0.0%, 64=0.0%, >=64=0.0%
     complete  : 0=0.0%, 4=100.0%, 8=0.0%, 16=0.0%, 32=0.0%, 64=0.0%, >=64=0.0%
     issued rwts: total=2439018,0,0,0 short=0,0,0,0 dropped=0,0,0,0
     latency   : target=0, window=0, percentile=100.00%, depth=1

Run status group 0 (all jobs):
   READ: bw=159MiB/s (167MB/s), 159MiB/s-159MiB/s (167MB/s-167MB/s), io=9527MiB (9990MB), run=60001-60001msec

Disk stats (read/write):
  vda: ios=2434208/33, merge=0/4, ticks=1883517/50, in_queue=12612, util=99.92%
```

random reads/writes:

```console
ubuntu@unencrypted-test:~$ sudo fio --name TEST --eta-newline=5s --filename=temp.file --rw=randrw --size=2g --io_size=10g --blocksize=4k --ioengine=libaio --fsync=1 --iodepth=1 --direct=1 --numjobs=1 --runtime=60 --group_reporting
TEST: (g=0): rw=randrw, bs=(R) 4096B-4096B, (W) 4096B-4096B, (T) 4096B-4096B, ioengine=libaio, iodepth=1
fio-3.16
Starting 1 process
Jobs: 1 (f=1): [m(1)][11.7%][r=1157KiB/s,w=1153KiB/s][r=289,w=288 IOPS][eta 00m:53s]
Jobs: 1 (f=1): [m(1)][21.7%][r=1080KiB/s,w=1000KiB/s][r=270,w=250 IOPS][eta 00m:47s] 
Jobs: 1 (f=1): [m(1)][31.7%][r=1137KiB/s,w=1105KiB/s][r=284,w=276 IOPS][eta 00m:41s] 
Jobs: 1 (f=1): [m(1)][41.7%][r=1104KiB/s,w=1116KiB/s][r=276,w=279 IOPS][eta 00m:35s] 
Jobs: 1 (f=1): [m(1)][51.7%][r=1309KiB/s,w=1193KiB/s][r=327,w=298 IOPS][eta 00m:29s] 
Jobs: 1 (f=1): [m(1)][61.7%][r=960KiB/s,w=872KiB/s][r=240,w=218 IOPS][eta 00m:23s]   
Jobs: 1 (f=1): [m(1)][71.7%][r=1209KiB/s,w=1181KiB/s][r=302,w=295 IOPS][eta 00m:17s] 
Jobs: 1 (f=1): [m(1)][81.7%][r=1208KiB/s,w=1124KiB/s][r=302,w=281 IOPS][eta 00m:11s] 
Jobs: 1 (f=1): [m(1)][91.7%][r=1237KiB/s,w=1173KiB/s][r=309,w=293 IOPS][eta 00m:05s]
Jobs: 1 (f=1): [m(1)][100.0%][r=1493KiB/s,w=1365KiB/s][r=373,w=341 IOPS][eta 00m:00s]
TEST: (groupid=0, jobs=1): err= 0: pid=3513: Tue Dec 19 18:36:33 2023
  read: IOPS=280, BW=1124KiB/s (1151kB/s)(65.8MiB/60005msec)
    slat (usec): min=3, max=147, avg=18.06, stdev= 6.82
    clat (usec): min=190, max=44898, avg=545.13, stdev=415.73
     lat (usec): min=199, max=44918, avg=563.48, stdev=416.51
    clat percentiles (usec):
     |  1.00th=[  293],  5.00th=[  338], 10.00th=[  379], 20.00th=[  429],
     | 30.00th=[  465], 40.00th=[  498], 50.00th=[  529], 60.00th=[  562],
     | 70.00th=[  586], 80.00th=[  611], 90.00th=[  660], 95.00th=[  717],
     | 99.00th=[ 1319], 99.50th=[ 1860], 99.90th=[ 2606], 99.95th=[ 3130],
     | 99.99th=[13304]
   bw (  KiB/s): min=  768, max= 1448, per=100.00%, avg=1123.58, stdev=142.03, samples=120
   iops        : min=  192, max=  362, avg=280.88, stdev=35.49, samples=120
  write: IOPS=280, BW=1123KiB/s (1150kB/s)(65.8MiB/60005msec); 0 zone resets
    slat (usec): min=4, max=422, avg=19.38, stdev= 7.70
    clat (usec): min=312, max=48241, avg=677.15, stdev=1649.18
     lat (usec): min=325, max=48256, avg=696.83, stdev=1649.39
    clat percentiles (usec):
     |  1.00th=[  392],  5.00th=[  429], 10.00th=[  445], 20.00th=[  474],
     | 30.00th=[  498], 40.00th=[  519], 50.00th=[  537], 60.00th=[  553],
     | 70.00th=[  570], 80.00th=[  594], 90.00th=[  668], 95.00th=[  824],
     | 99.00th=[ 2376], 99.50th=[ 5276], 99.90th=[30278], 99.95th=[42730],
     | 99.99th=[46400]
   bw (  KiB/s): min=  808, max= 1488, per=100.00%, avg=1122.66, stdev=134.73, samples=120
   iops        : min=  202, max=  372, avg=280.66, stdev=33.68, samples=120
  lat (usec)   : 250=0.10%, 500=35.26%, 750=59.57%, 1000=2.47%
  lat (msec)   : 2=1.61%, 4=0.70%, 10=0.12%, 20=0.08%, 50=0.11%
  fsync/fdatasync/sync_file_range:
    sync (nsec): min=20, max=15780, avg=235.58, stdev=180.99
    sync percentiles (nsec):
     |  1.00th=[   70],  5.00th=[   90], 10.00th=[  110], 20.00th=[  141],
     | 30.00th=[  161], 40.00th=[  191], 50.00th=[  211], 60.00th=[  241],
     | 70.00th=[  270], 80.00th=[  310], 90.00th=[  382], 95.00th=[  450],
     | 99.00th=[  604], 99.50th=[  676], 99.90th=[  964], 99.95th=[ 1224],
     | 99.99th=[ 6688]
  cpu          : usr=0.39%, sys=3.27%, ctx=79536, majf=0, minf=15
  IO depths    : 1=200.0%, 2=0.0%, 4=0.0%, 8=0.0%, 16=0.0%, 32=0.0%, >=64=0.0%
     submit    : 0=0.0%, 4=100.0%, 8=0.0%, 16=0.0%, 32=0.0%, 64=0.0%, >=64=0.0%
     complete  : 0=0.0%, 4=100.0%, 8=0.0%, 16=0.0%, 32=0.0%, 64=0.0%, >=64=0.0%
     issued rwts: total=16856,16842,0,33695 short=0,0,0,0 dropped=0,0,0,0
     latency   : target=0, window=0, percentile=100.00%, depth=1

Run status group 0 (all jobs):
   READ: bw=1124KiB/s (1151kB/s), 1124KiB/s-1124KiB/s (1151kB/s-1151kB/s), io=65.8MiB (69.0MB), run=60005-60005msec
  WRITE: bw=1123KiB/s (1150kB/s), 1123KiB/s-1123KiB/s (1150kB/s-1150kB/s), io=65.8MiB (68.0MB), run=60005-60005msec

Disk stats (read/write):
  vda: ios=16835/72046, merge=0/21536, ticks=9144/47927, in_queue=6776, util=99.90%
```

### Encrypted
`hdparm` results
* cached reads: 266.99 MB/sec
* disk reads: 175.85 MB/sec

```console
ubuntu@encrypted-test:~$ sudo hdparm --direct -t -T /dev/vda

/dev/vda:
 Timing O_DIRECT cached reads:   534 MB in  2.00 seconds = 266.99 MB/sec
 HDIO_DRIVE_CMD(identify) failed: Inappropriate ioctl for device
 Timing O_DIRECT disk reads: 528 MB in  3.00 seconds = 175.85 MB/sec
```

`dd` results:
*  (1.1 GB, 1.0 GiB) copied, 8.5209 s, 125 MB/s

```console
ubuntu@encrypted-test:~$ sudo dd if=/dev/zero of=test.file bs=64M count=16 oflag=dsync
16+0 records in
16+0 records out
1073741824 bytes (1.1 GB, 1.0 GiB) copied, 8.56711 s, 125 MB/s
```

`fio` results:
* sequential read: READ: bw=309MiB/s (324MB/s), 309MiB/s-309MiB/s (324MB/s-324MB/s), io=10.0GiB (10.7GB), run=33118-33118msec
* sequential write: WRITE: bw=134MiB/s (140MB/s), 134MiB/s-134MiB/s (140MB/s-140MB/s), io=8058MiB (8449MB), run=60238-60238msec
* random read: READ: bw=159MiB/s (167MB/s), 159MiB/s-159MiB/s (167MB/s-167MB/s), io=9558MiB (10.0GB), run=60001-60001msec
* random reads/writes:
  * READ: bw=1124KiB/s (1151kB/s), 1124KiB/s-1124KiB/s (1151kB/s-1151kB/s), io=65.8MiB (69.0MB), run=60005-60005msec
  * WRITE: bw=1123KiB/s (1150kB/s), 1123KiB/s-1123KiB/s (1150kB/s-1150kB/s), io=65.8MiB (68.0MB), run=60005-60005msec


sequential read:
```console
ubuntu@encrypted-test:~$ sudo fio --name TEST --eta-newline=5s --filename=temp.file --rw=read --size=2g --io_size=10g --blocksize=1024k --ioengine=libaio --fsync=10000 --iodepth=32 --direct=1 --numjobs=1 --runtime=60 --group_reporting
TEST: (g=0): rw=read, bs=(R) 1024KiB-1024KiB, (W) 1024KiB-1024KiB, (T) 1024KiB-1024KiB, ioengine=libaio, iodepth=32
fio-3.16
Starting 1 process
TEST: Laying out IO file (1 file / 2048MiB)
Jobs: 1 (f=1): [R(1)][25.8%][r=281MiB/s][r=281 IOPS][eta 00m:23s]
Jobs: 1 (f=1): [R(1)][38.9%][r=406MiB/s][r=406 IOPS][eta 00m:22s] 
Jobs: 1 (f=1): [R(1)][60.6%][r=406MiB/s][r=406 IOPS][eta 00m:13s] 
Jobs: 1 (f=1): [R(1)][76.5%][r=407MiB/s][r=407 IOPS][eta 00m:08s] 
Jobs: 1 (f=1): [R(1)][94.1%][r=423MiB/s][r=423 IOPS][eta 00m:02s] 
Jobs: 1 (f=1): [R(1)][100.0%][r=306MiB/s][r=306 IOPS][eta 00m:00s]
TEST: (groupid=0, jobs=1): err= 0: pid=2961: Tue Dec 19 20:24:33 2023
  read: IOPS=309, BW=309MiB/s (324MB/s)(10.0GiB/33118msec)
    slat (usec): min=12, max=574, avg=46.88, stdev=20.35
    clat (usec): min=1859, max=888134, avg=103374.48, stdev=119209.65
     lat (usec): min=1900, max=888203, avg=103421.69, stdev=119208.74
    clat percentiles (msec):
     |  1.00th=[    9],  5.00th=[   28], 10.00th=[   40], 20.00th=[   41],
     | 30.00th=[   44], 40.00th=[   84], 50.00th=[   92], 60.00th=[   96],
     | 70.00th=[  100], 80.00th=[  103], 90.00th=[  146], 95.00th=[  264],
     | 99.00th=[  693], 99.50th=[  709], 99.90th=[  735], 99.95th=[  877],
     | 99.99th=[  885]
   bw (  KiB/s): min=40960, max=475136, per=100.00%, avg=331489.65, stdev=120099.04, samples=63
   iops        : min=   40, max=  464, avg=323.71, stdev=117.28, samples=63
  lat (msec)   : 2=0.01%, 4=0.03%, 10=1.46%, 20=2.47%, 50=29.78%
  lat (msec)   : 100=38.98%, 250=21.75%, 500=2.08%, 750=3.37%, 1000=0.07%
  cpu          : usr=0.26%, sys=1.94%, ctx=9920, majf=0, minf=8206
  IO depths    : 1=0.1%, 2=0.1%, 4=0.2%, 8=0.4%, 16=0.8%, 32=98.5%, >=64=0.0%
     submit    : 0=0.0%, 4=100.0%, 8=0.0%, 16=0.0%, 32=0.0%, 64=0.0%, >=64=0.0%
     complete  : 0=0.0%, 4=100.0%, 8=0.0%, 16=0.0%, 32=0.1%, 64=0.0%, >=64=0.0%
     issued rwts: total=10240,0,0,0 short=0,0,0,0 dropped=0,0,0,0
     latency   : target=0, window=0, percentile=100.00%, depth=32

Run status group 0 (all jobs):
   READ: bw=309MiB/s (324MB/s), 309MiB/s-309MiB/s (324MB/s-324MB/s), io=10.0GiB (10.7GB), run=33118-33118msec

Disk stats (read/write):
  vda: ios=10479/44, merge=0/18, ticks=1077224/4100, in_queue=1060844, util=99.75%
```

sequential write:

```console
ubuntu@encrypted-test:~$ sudo fio --name TEST --eta-newline=5s --filename=temp.file --rw=write --size=2g --io_size=10g --blocksize=1024k --ioengine=libaio --fsync=10000 --iodepth=32 --direct=1 --numjobs=1 --runtime=60 --group_reporting
TEST: (g=0): rw=write, bs=(R) 1024KiB-1024KiB, (W) 1024KiB-1024KiB, (T) 1024KiB-1024KiB, ioengine=libaio, iodepth=32
fio-3.16
Starting 1 process
Jobs: 1 (f=1): [W(1)][11.7%][w=135MiB/s][w=135 IOPS][eta 00m:53s]
Jobs: 1 (f=1): [W(1)][21.7%][w=135MiB/s][w=135 IOPS][eta 00m:47s] 
Jobs: 1 (f=1): [W(1)][31.7%][w=135MiB/s][w=135 IOPS][eta 00m:41s] 
Jobs: 1 (f=1): [W(1)][41.7%][w=116MiB/s][w=116 IOPS][eta 00m:35s] 
Jobs: 1 (f=1): [W(1)][51.7%][w=146MiB/s][w=146 IOPS][eta 00m:29s] 
Jobs: 1 (f=1): [W(1)][61.7%][w=141MiB/s][w=141 IOPS][eta 00m:23s] 
Jobs: 1 (f=1): [W(1)][71.7%][w=131MiB/s][w=131 IOPS][eta 00m:17s] 
Jobs: 1 (f=1): [W(1)][81.7%][w=135MiB/s][w=135 IOPS][eta 00m:11s] 
Jobs: 1 (f=1): [W(1)][91.7%][w=122MiB/s][w=122 IOPS][eta 00m:05s] 
Jobs: 1 (f=1): [W(1)][100.0%][w=120MiB/s][w=120 IOPS][eta 00m:00s]
TEST: (groupid=0, jobs=1): err= 0: pid=2976: Tue Dec 19 20:26:47 2023
  write: IOPS=133, BW=134MiB/s (140MB/s)(8058MiB/60238msec); 0 zone resets
    slat (usec): min=16, max=183122, avg=348.41, stdev=6795.58
    clat (msec): min=19, max=415, avg=238.75, stdev=31.69
     lat (msec): min=26, max=415, avg=239.10, stdev=30.78
    clat percentiles (msec):
     |  1.00th=[  110],  5.00th=[  209], 10.00th=[  228], 20.00th=[  234],
     | 30.00th=[  236], 40.00th=[  236], 50.00th=[  236], 60.00th=[  239],
     | 70.00th=[  239], 80.00th=[  243], 90.00th=[  257], 95.00th=[  275],
     | 99.00th=[  376], 99.50th=[  388], 99.90th=[  405], 99.95th=[  405],
     | 99.99th=[  418]
   bw (  KiB/s): min=118784, max=145408, per=99.98%, avg=136956.29, stdev=4654.02, samples=120
   iops        : min=  116, max=  142, avg=133.69, stdev= 4.53, samples=120
  lat (msec)   : 20=0.01%, 50=0.22%, 100=0.57%, 250=85.94%, 500=13.25%
  cpu          : usr=0.61%, sys=1.02%, ctx=7493, majf=0, minf=13
  IO depths    : 1=0.1%, 2=0.1%, 4=0.2%, 8=0.4%, 16=0.8%, 32=98.5%, >=64=0.0%
     submit    : 0=0.0%, 4=100.0%, 8=0.0%, 16=0.0%, 32=0.0%, 64=0.0%, >=64=0.0%
     complete  : 0=0.0%, 4=99.9%, 8=0.0%, 16=0.0%, 32=0.1%, 64=0.0%, >=64=0.0%
     issued rwts: total=0,8058,0,0 short=0,0,0,0 dropped=0,0,0,0
     latency   : target=0, window=0, percentile=100.00%, depth=32

Run status group 0 (all jobs):
  WRITE: bw=134MiB/s (140MB/s), 134MiB/s-134MiB/s (140MB/s-140MB/s), io=8058MiB (8449MB), run=60238-60238msec

Disk stats (read/write):
  vda: ios=0/8344, merge=0/17, ticks=0/1952171, in_queue=1935760, util=99.86%
```

random read:

```console
ubuntu@encrypted-test:~$ sudo fio --name TEST --eta-newline=5s --filename=temp.file --rw=randread --size=2g --io_size=10g --blocksize=4k --ioengine=libaio --fsync=1 --iodepth=1 --direct=1 --numjobs=32 --runtime=60 --group_reporting
TEST: (g=0): rw=randread, bs=(R) 4096B-4096B, (W) 4096B-4096B, (T) 4096B-4096B, ioengine=libaio, iodepth=1
...
fio-3.16
Starting 32 processes
Jobs: 32 (f=32): [r(32)][11.7%][r=157MiB/s][r=40.3k IOPS][eta 00m:53s]
Jobs: 32 (f=32): [r(32)][21.7%][r=161MiB/s][r=41.3k IOPS][eta 00m:47s] 
Jobs: 32 (f=32): [r(32)][31.7%][r=161MiB/s][r=41.2k IOPS][eta 00m:41s] 
Jobs: 32 (f=32): [r(32)][41.7%][r=157MiB/s][r=40.1k IOPS][eta 00m:35s] 
Jobs: 32 (f=32): [r(32)][51.7%][r=158MiB/s][r=40.5k IOPS][eta 00m:29s] 
Jobs: 32 (f=32): [r(32)][61.7%][r=165MiB/s][r=42.1k IOPS][eta 00m:23s] 
Jobs: 32 (f=32): [r(32)][71.7%][r=163MiB/s][r=41.7k IOPS][eta 00m:17s] 
Jobs: 32 (f=32): [r(32)][81.7%][r=162MiB/s][r=41.5k IOPS][eta 00m:11s] 
Jobs: 32 (f=32): [r(32)][91.7%][r=157MiB/s][r=40.1k IOPS][eta 00m:05s] 
Jobs: 32 (f=32): [r(32)][100.0%][r=161MiB/s][r=41.2k IOPS][eta 00m:00s]
TEST: (groupid=0, jobs=32): err= 0: pid=2983: Tue Dec 19 20:28:36 2023
  read: IOPS=40.8k, BW=159MiB/s (167MB/s)(9558MiB/60001msec)
    slat (nsec): min=1332, max=2685.8k, avg=7746.39, stdev=14011.13
    clat (nsec): min=561, max=18004k, avg=775416.34, stdev=324454.21
     lat (usec): min=200, max=18017, avg=783.33, stdev=324.44
    clat percentiles (usec):
     |  1.00th=[  408],  5.00th=[  490], 10.00th=[  537], 20.00th=[  594],
     | 30.00th=[  644], 40.00th=[  685], 50.00th=[  717], 60.00th=[  758],
     | 70.00th=[  807], 80.00th=[  873], 90.00th=[ 1045], 95.00th=[ 1237],
     | 99.00th=[ 1926], 99.50th=[ 2442], 99.90th=[ 4228], 99.95th=[ 5211],
     | 99.99th=[ 7767]
   bw (  KiB/s): min=131568, max=176136, per=99.99%, avg=163092.77, stdev=247.89, samples=3814
   iops        : min=32892, max=44034, avg=40772.61, stdev=61.98, samples=3814
  lat (nsec)   : 750=0.01%, 1000=0.01%
  lat (usec)   : 2=0.01%, 10=0.01%, 50=0.01%, 100=0.01%, 250=0.01%
  lat (usec)   : 500=5.83%, 750=52.09%, 1000=30.52%
  lat (msec)   : 2=10.65%, 4=0.78%, 10=0.11%, 20=0.01%
  cpu          : usr=0.33%, sys=2.24%, ctx=2446955, majf=0, minf=414
  IO depths    : 1=100.0%, 2=0.0%, 4=0.0%, 8=0.0%, 16=0.0%, 32=0.0%, >=64=0.0%
     submit    : 0=0.0%, 4=100.0%, 8=0.0%, 16=0.0%, 32=0.0%, 64=0.0%, >=64=0.0%
     complete  : 0=0.0%, 4=100.0%, 8=0.0%, 16=0.0%, 32=0.0%, 64=0.0%, >=64=0.0%
     issued rwts: total=2446782,0,0,0 short=0,0,0,0 dropped=0,0,0,0
     latency   : target=0, window=0, percentile=100.00%, depth=1

Run status group 0 (all jobs):
   READ: bw=159MiB/s (167MB/s), 159MiB/s-159MiB/s (167MB/s-167MB/s), io=9558MiB (10.0GB), run=60001-60001msec

Disk stats (read/write):
  vda: ios=2442118/31, merge=0/6, ticks=1883054/44, in_queue=12096, util=99.97%
```

random reads/writes:

```console
ubuntu@encrypted-test:~$ sudo fio --name TEST --eta-newline=5s --filename=temp.file --rw=randrw --size=2g --io_size=10g --blocksize=4k --ioengine=libaio --fsync=1 --iodepth=1 --direct=1 --numjobs=1 --runtime=60 --group_reporting
TEST: (g=0): rw=randrw, bs=(R) 4096B-4096B, (W) 4096B-4096B, (T) 4096B-4096B, ioengine=libaio, iodepth=1
fio-3.16
Starting 1 process
Jobs: 1 (f=1): [m(1)][11.7%][r=1057KiB/s,w=1193KiB/s][r=264,w=298 IOPS][eta 00m:53s]
Jobs: 1 (f=1): [m(1)][21.7%][r=1280KiB/s,w=1184KiB/s][r=320,w=296 IOPS][eta 00m:47s] 
Jobs: 1 (f=1): [m(1)][31.7%][r=1157KiB/s,w=1049KiB/s][r=289,w=262 IOPS][eta 00m:41s] 
Jobs: 1 (f=1): [m(1)][41.7%][r=1137KiB/s,w=1121KiB/s][r=284,w=280 IOPS][eta 00m:35s] 
Jobs: 1 (f=1): [m(1)][51.7%][r=1164KiB/s,w=1208KiB/s][r=291,w=302 IOPS][eta 00m:29s] 
Jobs: 1 (f=1): [m(1)][61.7%][r=1297KiB/s,w=1177KiB/s][r=324,w=294 IOPS][eta 00m:23s] 
Jobs: 1 (f=1): [m(1)][71.7%][r=1233KiB/s,w=1225KiB/s][r=308,w=306 IOPS][eta 00m:17s] 
Jobs: 1 (f=1): [m(1)][81.7%][r=1244KiB/s,w=1232KiB/s][r=311,w=308 IOPS][eta 00m:11s] 
Jobs: 1 (f=1): [m(1)][91.7%][r=1213KiB/s,w=1113KiB/s][r=303,w=278 IOPS][eta 00m:05s]
Jobs: 1 (f=1): [m(1)][100.0%][r=1041KiB/s,w=1025KiB/s][r=260,w=256 IOPS][eta 00m:00s]
TEST: (groupid=0, jobs=1): err= 0: pid=3018: Tue Dec 19 20:30:01 2023
  read: IOPS=288, BW=1156KiB/s (1183kB/s)(67.7MiB/60001msec)
    slat (usec): min=3, max=114, avg=17.89, stdev= 6.80
    clat (usec): min=200, max=17210, avg=530.55, stdev=244.56
     lat (usec): min=204, max=17222, avg=548.75, stdev=245.86
    clat percentiles (usec):
     |  1.00th=[  289],  5.00th=[  334], 10.00th=[  367], 20.00th=[  424],
     | 30.00th=[  457], 40.00th=[  490], 50.00th=[  519], 60.00th=[  545],
     | 70.00th=[  570], 80.00th=[  603], 90.00th=[  644], 95.00th=[  701],
     | 99.00th=[ 1156], 99.50th=[ 1762], 99.90th=[ 2868], 99.95th=[ 3654],
     | 99.99th=[ 8717]
   bw (  KiB/s): min=  632, max= 1504, per=100.00%, avg=1156.99, stdev=153.76, samples=119
   iops        : min=  158, max=  376, avg=289.24, stdev=38.44, samples=119
  write: IOPS=288, BW=1155KiB/s (1182kB/s)(67.7MiB/60001msec); 0 zone resets
    slat (usec): min=3, max=481, avg=19.22, stdev= 7.65
    clat (usec): min=291, max=58682, avg=656.54, stdev=1599.46
     lat (usec): min=296, max=58697, avg=676.08, stdev=1599.68
    clat percentiles (usec):
     |  1.00th=[  379],  5.00th=[  416], 10.00th=[  433], 20.00th=[  461],
     | 30.00th=[  486], 40.00th=[  506], 50.00th=[  523], 60.00th=[  537],
     | 70.00th=[  562], 80.00th=[  586], 90.00th=[  652], 95.00th=[  807],
     | 99.00th=[ 2311], 99.50th=[ 3916], 99.90th=[33424], 99.95th=[36439],
     | 99.99th=[45876]
   bw (  KiB/s): min=  792, max= 1548, per=100.00%, avg=1156.24, stdev=127.97, samples=119
   iops        : min=  198, max=  387, avg=289.05, stdev=31.99, samples=119
  lat (usec)   : 250=0.12%, 500=40.12%, 750=55.14%, 1000=2.19%
  lat (msec)   : 2=1.58%, 4=0.59%, 10=0.09%, 20=0.08%, 50=0.10%
  lat (msec)   : 100=0.01%
  fsync/fdatasync/sync_file_range:
    sync (nsec): min=40, max=27421, avg=292.55, stdev=286.81
    sync percentiles (nsec):
     |  1.00th=[   90],  5.00th=[  131], 10.00th=[  151], 20.00th=[  191],
     | 30.00th=[  211], 40.00th=[  231], 50.00th=[  251], 60.00th=[  282],
     | 70.00th=[  322], 80.00th=[  370], 90.00th=[  462], 95.00th=[  564],
     | 99.00th=[  852], 99.50th=[  972], 99.90th=[ 1288], 99.95th=[ 1576],
     | 99.99th=[17024]
  cpu          : usr=0.44%, sys=3.23%, ctx=81851, majf=0, minf=14
  IO depths    : 1=200.0%, 2=0.0%, 4=0.0%, 8=0.0%, 16=0.0%, 32=0.0%, >=64=0.0%
     submit    : 0=0.0%, 4=100.0%, 8=0.0%, 16=0.0%, 32=0.0%, 64=0.0%, >=64=0.0%
     complete  : 0=0.0%, 4=100.0%, 8=0.0%, 16=0.0%, 32=0.0%, 64=0.0%, >=64=0.0%
     issued rwts: total=17333,17322,0,34652 short=0,0,0,0 dropped=0,0,0,0
     latency   : target=0, window=0, percentile=100.00%, depth=1

Run status group 0 (all jobs):
   READ: bw=1156KiB/s (1183kB/s), 1156KiB/s-1156KiB/s (1183kB/s-1183kB/s), io=67.7MiB (70.0MB), run=60001-60001msec
   WRITE: bw=1155KiB/s (1182kB/s), 1155KiB/s-1155KiB/s (1182kB/s-1182kB/s), io=67.7MiB (70.9MB), run=60001-60001msec

```


### NEW for Longhorn 1.6+ / Harvester 1.3 +

Changes occurred in Longhorn 1.6 that have impacted the functionality above. For encryption, backing images in Longhorn 1.5.x were never passed through encryption or decryption as they were static images that did not change. Block mode volumes were never decrypted as block mode was not supported. So the base image was left intact but the snapshot-based layer changes over time as the VM ran would be. Snapshots and filesystem mode volumes were encrypted at rest.

In Longhorn 1.6.x, block mode volumes are now supported for encryption/decryption but still not for backing images. This puts Harvester into a weird state as it uses both block mode volumes and backing images for root volumes. Since Harvester still does not officially support encrypted root volumes yet, the fix for 1.2.1/2 broke. Longhorn was now suddenly expecting block volumes to have been previously encrypted. Longhorn does not provide a capability of encrypting backing images. So we are in a chicken/egg issue. EaR official support is coming in 1.4 and Longhorn's update to block mode support was part of this.

Fortunately, this can be fixed but the workaround requires a few extra steps including the original though they will not be too difficult to wrap into existing automation workflows. Essentially, encrytion of the root volume image has to happen before it is uploaded to Harvester.

This process breaks down into two parts:
1) Encrypting the Backing image
2) Installing cryptsetup onto Harvester

After you have completed these two steps, your resulting image loaded into longhorn will need to have its storage class changed as before to add the decryption keys.

### Encrypting the Backing Image
Encrypting the backing image requires manual encryption of the backing image. Luckily, on a standard linux workstation, this is easy and can be tied into Packer or other automation steps. There is a simple script available at [scripts/encrypt_base_image.sh](scripts/encrypt_base_image.sh) to help accelerate but I will explain what is happening below.

We need to build an output file that we can write the encrypted data to, so use `truncate` in this case. The size should be whatever your source image size is (I'm using Ubuntu cloudimg here). Note that this is a QCOW image for Harvester's consumption, it is not a single partition so I need to mount this device using qemu-friendly tools, I use `qemu-nbd`.

Since I am writing a QCOW disk image, the physical size of the input image file is not the same as the size of the partitions within. I am guessing at 3Gigs for size since my Ubuntu cloud image is 2.5Gb total uncompressed. I am creating an empty file of 3GB in size. If you are using a different qcow-base image, then you will need to take a look at the total size to choose the proper size for yourself.

You can do this via the `qemu-nbd` tool. Mount the qcow image and then use fdisk to analyze the size:
```bash
sudo qemu-nbd --connect=/dev/nbd0 image
sudo fdisk /dev/nbd0 -l
sudo qemu-nbd -d /dev/nbd0
```

Based on that info, I'm using 3Gb for my image. We need the file size to be a little larger to account for the luks metadata
```bash
TRUNC_SIZE=3G
truncate -s $TRUNC_SIZE image-encrypted.img
```

Next we create a loop device that we'll use for writing to the image file directly. I am fetching the next available loop device from the `losetup` command so I don't have to manually find one:
```bash
LOOP_DEVICE=$(sudo losetup -f)
sudo losetup $LOOP_DEVICE image-encrypted.img   
```

Next we use cryptsetup to initialize the image with all of our encryption configs. These values are pulled directly from our examples of above when configuring a longhorn encryption secret. The variable names should be obvious but how I fetch these values from the harvester cluster is included in the [script file](scripts/encrypt_base_image.sh).

```bash
echo -n $CRYPTO_KEY_VALUE | sudo cryptsetup -q luksFormat --type luks2 --cipher $CRYPTO_KEY_CIPHER --hash $CRYPTO_KEY_HASH --key-size $CRYPTO_KEY_SIZE --pbkdf $CRYPTO_PBKDF $LOOP_DEVICE -
echo -n $CRYPTO_KEY_VALUE | sudo cryptsetup luksOpen $LOOP_DEVICE image-encrypted.img -
```

Once cryptsetup has been initialized, I can mount the QCOW image as an NBD device and then use `dd` to copy the NBD device to the destination mapped device. This might take a minute or two.

```bash
sudo qemu-nbd --connect=/dev/nbd0 image
sudo dd if=image of=/dev/mapper/image-encrypted.img
sudo losetup -d $LOOP_DEVICE
```

The resulting image at `image-encrypted.img` can now be uploaded into Harvester as a VirtualMachineImage type.

I clean up my disk mappings:
```bash
sudo cryptsetup luksClose encryption
sudo losetup -d $LOOP_DEVICE
sudo qemu-nbd -d /dev/nbd0
```

Now I run this script to create and test it as an example. I am pulling my ubuntu image from a local fileserver for speed:

```console
$ ./encrypt_base_image.sh http://10.0.0.90:9900/ubuntu-20.04-server-cloudimg-amd64.img longhorn-crypto
Downloading VM image from http://10.0.0.90:9900/ubuntu-20.04-server-cloudimg-amd64.img
  % Total    % Received % Xferd  Average Speed   Time    Time     Time  Current
                                 Dload  Upload   Total   Spent    Left  Speed
100  575M  100  575M    0     0  52.0M      0  0:00:11  0:00:11 --:--:-- 48.2M
Grabbing Longhorn encryption details from secret longhorn-crypto
Creating output file for writing
[sudo] password for deathstar: 
Creating loop device for writing
Using cryptsetup to prepare luks2
Writing file as QCOW image
4612096+0 records in
4612096+0 records out
2361393152 bytes (2.4 GB, 2.2 GiB) copied, 17.9856 s, 131 MB/s
/dev/nbd0 disconnected
Upload this file to Longhorn as a VM image
```

Now I verify everything is in-tact
```console
$ ./verify_encryption.sh image-encrypted.img longhorn-crypto
Grabbing Longhorn encryption details from secret longhorn-crypto
GPT PMBR size mismatch (4612095 != 6258687) will be corrected by write.
The backup GPT table is not on the end of the device.
Disk /dev/mapper/encryption: 2.98 GiB, 3204448256 bytes, 6258688 sectors
Units: sectors of 1 * 512 = 512 bytes
Sector size (logical/physical): 512 bytes / 512 bytes
I/O size (minimum/optimal): 512 bytes / 512 bytes
Disklabel type: gpt
Disk identifier: 58F4D642-A551-4973-8255-533ACFAF91DE

Device                         Start     End Sectors  Size Type
/dev/mapper/encryption-part1  227328 4612062 4384735  2.1G Linux filesystem
/dev/mapper/encryption-part14   2048   10239    8192    4M BIOS boot
/dev/mapper/encryption-part15  10240  227327  217088  106M EFI System

Partition table entries are not in disk order.
If successful, fdisk will show the in-tact disk partitions in the image. If you see sizing errors in red at the top, that likely is not a problem
```

I can now upload this img file to Harvester as an encryted virtual machine image


### cryptsetup on Harvester
This is an involved process because Harvester's OS image is immutable and designed to not be modified. Since Longhorn uses cryptsetup on the host IPC, we have to update every host node by installing cryptsetup. This requires entering a specific boot mode in order to write to the main partition. Doing this process during installation is SIGNIFICANTLY less complicated.

For more detailed notes [click here](https://docs.harvesterhci.io/v1.3/troubleshooting/os#how-can-i-install-packages-why-are-some-paths-read-only)

For each node, write this file:
```bash
cat > /oem/91_hack.yaml <<'EOF'
name: "Rootfs Layout Settings for debugrw"
stages:
  rootfs:
    - if: 'grep -q root=LABEL=COS_STATE /proc/cmdline && grep -q rd.cos.debugrw /proc/cmdline'
      name: "Layout configuration for debugrw"
      environment_file: /run/cos/cos-layout.env
      environment:
        RW_PATHS: " "
EOF
```

Reboot the node and hit 'e' when the grub boot menu appears (yes you will need to be KVM'd or direct access to the console). On the line beginning with `linux` scroll to the end of that line (it wraps) and add `rd.cos.debugrw`. Hit F10 to boot the node.

Now the node's root file system is writeable. You can either enter via console once it is booted or hop in via SSH.

Use the OpenSUSE leap repo that holds cryptsetup and install it. The refresh command requires manual entry of `a` to accept the upstream signing key
```bash
zypper addrepo http://download.opensuse.org/distribution/leap/15.5/repo/oss/  main
zypper refresh
zypper install -y --no-recommends cryptsetup
```

Once cryptsetup is installed, let's cleanup:
```bash
rm /oem/91_hack.yaml
zypper clean
zypper removerepo 1
```

Once you reboot, your node will be read-only again. Repeat this process for all nodes.

At this point, encryption at rest should function as before. Whenever new VM images are needed, their backing image needs to be encrypted first. This will no longer be necessary with Harvester 1.4's native support.

## PXE Boot and cryptsetup
Installing `cryptsetup` is very easy when using PXE booting for Harvester. Within Harvester's yaml configuration spec per node, there is a field called `after_install_chroot_commands`. The field is documented [here](https://docs.harvesterhci.io/v1.2/install/harvester-configuration#osafter_install_chroot_commands).

Using this field with the above instructions with zypper, the cryptsetup install can be performed without the special grub settings at all. Use this set of commands:

```yaml
os:
  after_install_chroot_commands:
    - "rm -f /etc/resolv.conf && echo 'nameserver 8.8.8.8' | sudo tee /etc/resolv.conf"
    - zypper addrepo http://download.opensuse.org/distribution/leap/15.5/repo/oss/  main
    - zypper refresh
    - zypper install -y --no-recommends cryptsetup
    - zypper clean
    - zypper removerepo 1
    - "rm -f /etc/resolv.conf && ln -s /var/run/netconfig/resolv.conf /etc/resolv.conf"
```