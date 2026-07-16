#!/bin/bash

PASSWORD="mypw" # replace with your desired password
ROOT_CN="oda_root"
# Child nodes act as servers, requiring IPs for SAN fields.
# Format: "inventory_hostname:IP_Address", replace with the actual IP addresses of the child nodes
CHILD_NODES=("oda_child_1:child1ipaddress" "oda_child_2:child2ipaddress")
OUT_DIR="oda_certs_output"

echo "starting ODA mTLS certificates generation for Root-Pull"

rm -rf $OUT_DIR
mkdir -p $OUT_DIR/ca
cd $OUT_DIR

# 1. CA (Certificate Authority)
echo "generating CA"
openssl req -new -newkey rsa:4096 -days 3650 -x509 \
  -subj "/CN=ODA-Internal-CA" \
  -keyout ca/ca-key -out ca/ca-cert -nodes > /dev/null 2>&1

# ==============================================================================
# 2. CHILD SERVERS & ROOT MM2 CLIENTS
# ==============================================================================
# The root does not expose the broker, thus it has no server certificates.
# We generate server certs for the children and the corresponding client certs for the root.

mkdir -p $ROOT_CN

for NODE in "${CHILD_NODES[@]}"; do
  CHILD="${NODE%%:*}"
  CHILD_IP="${NODE##*:}"

  # Extract the index from the child name (e.g., from "oda_child_1" we get "1")
  # and use it to create the client CN (e.g., "oda_root_1")
  CHILD_INDEX="${CHILD##*_}"
  CLIENT_CN="oda_root_${CHILD_INDEX}"

  echo "generating server certs for $CHILD and client certs for $CLIENT_CN"

  # Create directories respecting the naming convention
  mkdir -p $CHILD
  mkdir -p $ROOT_CN/$CHILD

  # ----------------------------------------------------------------------------
  # CHILD NODE: SERVER KEYSTORE & TRUSTSTORE
  # ----------------------------------------------------------------------------
  # Truststore
  keytool -keystore $CHILD/kafka.server.truststore.jks -alias CARoot -import -file ca/ca-cert -storepass $PASSWORD -noprompt > /dev/null 2>&1

  # Keystore and Sign (Child is the server, requires SAN with its IP)
  keytool -genkey -keystore $CHILD/kafka.server.keystore.jks -alias server -dname "CN=$CHILD" \
    -keyalg RSA -storepass $PASSWORD -keypass $PASSWORD \
    -ext SAN=DNS:localhost,IP:127.0.0.1,IP:0.0.0.0,IP:$CHILD_IP > /dev/null 2>&1

  keytool -keystore $CHILD/kafka.server.keystore.jks -alias server -certreq -file $CHILD/server-req -storepass $PASSWORD > /dev/null 2>&1

  echo "subjectAltName=DNS:localhost,IP:127.0.0.1,IP:0.0.0.0,IP:$CHILD_IP" > $CHILD/extfile.cnf

  openssl x509 -req -CA ca/ca-cert -CAkey ca/ca-key -in $CHILD/server-req -out $CHILD/server-cert -days 365 -CAcreateserial -passin pass:$PASSWORD -extfile $CHILD/extfile.cnf > /dev/null 2>&1

  keytool -keystore $CHILD/kafka.server.keystore.jks -alias CARoot -import -file ca/ca-cert -storepass $PASSWORD -noprompt > /dev/null 2>&1
  keytool -keystore $CHILD/kafka.server.keystore.jks -alias server -import -file $CHILD/server-cert -storepass $PASSWORD -noprompt > /dev/null 2>&1

  # ----------------------------------------------------------------------------
  # ROOT NODE: MM2 CLIENT KEYSTORE & TRUSTSTORE FOR THIS SPECIFIC CHILD
  # ----------------------------------------------------------------------------
  CLIENT_DIR="$ROOT_CN/$CHILD"

  # Truststore
  keytool -keystore $CLIENT_DIR/kafka.client.truststore.jks -alias CARoot -import -file ca/ca-cert -storepass $PASSWORD -noprompt > /dev/null 2>&1

  # Keystore and Sign (Use the new CLIENT_CN)
  keytool -genkey -keystore $CLIENT_DIR/kafka.client.keystore.jks -alias client -dname "CN=$CLIENT_CN" \
    -keyalg RSA -storepass $PASSWORD -keypass $PASSWORD > /dev/null 2>&1
  keytool -keystore $CLIENT_DIR/kafka.client.keystore.jks -alias client -certreq -file $CLIENT_DIR/client-req -storepass $PASSWORD > /dev/null 2>&1
  openssl x509 -req -CA ca/ca-cert -CAkey ca/ca-key -in $CLIENT_DIR/client-req -out $CLIENT_DIR/client-cert -days 365 -CAcreateserial -passin pass:$PASSWORD > /dev/null 2>&1
  keytool -keystore $CLIENT_DIR/kafka.client.keystore.jks -alias CARoot -import -file ca/ca-cert -storepass $PASSWORD -noprompt > /dev/null 2>&1
  keytool -keystore $CLIENT_DIR/kafka.client.keystore.jks -alias client -import -file $CLIENT_DIR/client-cert -storepass $PASSWORD -noprompt > /dev/null 2>&1

done

# Cleaning
echo "cleaning csr and temporary files"
find . -name "*-req" -delete
find . -name "*-cert" -delete
find . -name "*.srl" -delete
find . -name "*.cnf" -delete

echo "finished! Output in '$OUT_DIR'"
