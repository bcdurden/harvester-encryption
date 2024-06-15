#!/bin/bash

# 
IMAGE=$1
# LONGHORN_SECRET_NAME=longhorn-crypto 
LONGHORN_SECRET_NAME=$2 

# fetch the encryption details
echo "Grabbing Longhorn encryption details from secret $2"
CRYPTO_KEY_VALUE=$(kubectl get secret -n longhorn-system $LONGHORN_SECRET_NAME -o=go-template --template={{.data.CRYPTO_KEY_VALUE}} | base64 -d)
CRYPTO_KEY_CIPHER=$(kubectl get secret -n longhorn-system $LONGHORN_SECRET_NAME -o=go-template --template={{.data.CRYPTO_KEY_CIPHER}} | base64 -d)
CRYPTO_KEY_HASH=$(kubectl get secret -n longhorn-system $LONGHORN_SECRET_NAME -o=go-template --template={{.data.CRYPTO_KEY_HASH}} | base64 -d)
CRYPTO_KEY_SIZE=$(kubectl get secret -n longhorn-system $LONGHORN_SECRET_NAME -o=go-template --template={{.data.CRYPTO_KEY_SIZE}} | base64 -d)
CRYPTO_PBKDF=$(kubectl get secret -n longhorn-system $LONGHORN_SECRET_NAME -o=go-template --template={{.data.CRYPTO_PBKDF}} | base64 -d)

echo -n $CRYPTO_KEY_VALUE | sudo cryptsetup luksOpen $IMAGE encryption -
sudo fdisk /dev/mapper/encryption -l
sudo cryptsetup luksClose encryption 

echo "If successful, fdisk will show the in-tact disk partitions in the image. If you see sizing errors in red at the top, that likely is not a problem"