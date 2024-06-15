#!/bin/bash

# grab img
# truncate and copy
# 
IMAGE_URL=$1
LONGHORN_SECRET_NAME=$2 #longhorn-crypto 

echo "Downloading VM image from $IMAGE_URL"
curl $IMAGE_URL -o image

# fetch the encryption details
echo "Grabbing Longhorn encryption details from secret $2"
CRYPTO_KEY_VALUE=$(kubectl get secret -n longhorn-system $LONGHORN_SECRET_NAME -o=go-template --template={{.data.CRYPTO_KEY_VALUE}} | base64 -d)
CRYPTO_KEY_CIPHER=$(kubectl get secret -n longhorn-system $LONGHORN_SECRET_NAME -o=go-template --template={{.data.CRYPTO_KEY_CIPHER}} | base64 -d)
CRYPTO_KEY_HASH=$(kubectl get secret -n longhorn-system $LONGHORN_SECRET_NAME -o=go-template --template={{.data.CRYPTO_KEY_HASH}} | base64 -d)
CRYPTO_KEY_SIZE=$(kubectl get secret -n longhorn-system $LONGHORN_SECRET_NAME -o=go-template --template={{.data.CRYPTO_KEY_SIZE}} | base64 -d)
CRYPTO_PBKDF=$(kubectl get secret -n longhorn-system $LONGHORN_SECRET_NAME -o=go-template --template={{.data.CRYPTO_PBKDF}} | base64 -d)

echo "Creating output file for writing"
# IMG_SIZE=$(stat --printf="%s" image)
TRUNC_SIZE=3G #$(echo $(($IMG_SIZE+33554432)))
LOOP_DEVICE=$(sudo losetup -f)
truncate -s $TRUNC_SIZE image-encrypted.img

echo "Creating loop device for writing"
sudo losetup $LOOP_DEVICE image-encrypted.img   

echo "Using cryptsetup to prepare luks2"
echo -n $CRYPTO_KEY_VALUE | sudo cryptsetup -q luksFormat --type luks2 --cipher $CRYPTO_KEY_CIPHER --hash $CRYPTO_KEY_HASH --key-size $CRYPTO_KEY_SIZE --pbkdf $CRYPTO_PBKDF $LOOP_DEVICE -
echo -n $CRYPTO_KEY_VALUE | sudo cryptsetup luksOpen $LOOP_DEVICE encryption -

echo "Writing file as QCOW image"
sudo qemu-nbd --connect=/dev/nbd0 image
sudo dd if=/dev/nbd0 of=/dev/mapper/encryption
sudo cryptsetup luksClose encryption
sudo losetup -d $LOOP_DEVICE
sudo qemu-nbd -d /dev/nbd0

echo "Upload this file to Longhorn as a VM image"