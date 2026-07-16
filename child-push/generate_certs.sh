#!/bin/bash

PASSWORD="mypw" # replace with your desired password
ROOT_CN="oda_root"
ROOT_IP="rootipaddress" # replace with the actual IP address of the root node
CHILD_NODES=("oda_child_1" "oda_child_2") # use ansible inventory naming
OUT_DIR="oda_certs_output"

echo "starting ODA mTLS certificates generation "

rm -rf $OUT_DIR
mkdir -p $OUT_DIR/ca
cd $OUT_DIR

# 1. CA (Certificate Authority)
echo "generating CA"
openssl req -new -newkey rsa:4096 -days 3650 -x509 \
  -subj "/CN=ODA-Internal-CA" \
  -keyout ca/ca-key -out ca/ca-cert -nodes > /dev/null 2>&1

# ==============================================================================
# 2. ROOT BROKER
# ==============================================================================
echo "generating keystore and truststore server for root broker"

mkdir -p $ROOT_CN

# Truststore
keytool -keystore $ROOT_CN/kafka.server.truststore.jks -alias CARoot -import -file ca/ca-cert -storepass $PASSWORD -noprompt > /dev/null 2>&1

# Keystore and Signing
keytool -genkey -keystore $ROOT_CN/kafka.server.keystore.jks -alias server -dname "CN=$ROOT_CN" \
  -keyalg RSA -storepass $PASSWORD -keypass $PASSWORD \
  -ext SAN=DNS:localhost,IP:127.0.0.1,IP:0.0.0.0,IP:$ROOT_IP > /dev/null 2>&1

keytool -keystore $ROOT_CN/kafka.server.keystore.jks -alias server -certreq -file $ROOT_CN/server-req -storepass $PASSWORD > /dev/null 2>&1

echo "subjectAltName=DNS:localhost,IP:127.0.0.1,IP:0.0.0.0,IP:$ROOT_IP" > $ROOT_CN/extfile.cnf

openssl x509 -req -CA ca/ca-cert -CAkey ca/ca-key -in $ROOT_CN/server-req -out $ROOT_CN/server-cert -days 365 -CAcreateserial -passin pass:$PASSWORD -extfile $ROOT_CN/extfile.cnf > /dev/null 2>&1

keytool -keystore $ROOT_CN/kafka.server.keystore.jks -alias CARoot -import -file ca/ca-cert -storepass $PASSWORD -noprompt > /dev/null 2>&1
keytool -keystore $ROOT_CN/kafka.server.keystore.jks -alias server -import -file $ROOT_CN/server-cert -storepass $PASSWORD -noprompt > /dev/null 2>&1

# ==============================================================================
# 3. CHILD NODES
# ==============================================================================
for CHILD in "${CHILD_NODES[@]}"; do
  echo "generating keystore and truststore client for $CHILD"
  mkdir -p $CHILD

  # Truststore
  keytool -keystore $CHILD/kafka.client.truststore.jks -alias CARoot -import -file ca/ca-cert -storepass $PASSWORD -noprompt > /dev/null 2>&1

  # Keystore and Sign (CN matches ansible naming)
  keytool -genkey -keystore $CHILD/kafka.client.keystore.jks -alias client -dname "CN=$CHILD" \
    -keyalg RSA -storepass $PASSWORD -keypass $PASSWORD > /dev/null 2>&1
  keytool -keystore $CHILD/kafka.client.keystore.jks -alias client -certreq -file $CHILD/client-req -storepass $PASSWORD > /dev/null 2>&1
  openssl x509 -req -CA ca/ca-cert -CAkey ca/ca-key -in $CHILD/client-req -out $CHILD/client-cert -days 365 -CAcreateserial -passin pass:$PASSWORD > /dev/null 2>&1
  keytool -keystore $CHILD/kafka.client.keystore.jks -alias CARoot -import -file ca/ca-cert -storepass $PASSWORD -noprompt > /dev/null 2>&1
  keytool -keystore $CHILD/kafka.client.keystore.jks -alias client -import -file $CHILD/client-cert -storepass $PASSWORD -noprompt > /dev/null 2>&1
done

# Cleaning
echo "cleaning csr and temporary files"
find . -name "*-req" -delete
find . -name "*-cert" -delete
find . -name "*.srl" -delete
find . -name "*.cnf" -delete

echo "finished! Output in '$OUT_DIR'"
