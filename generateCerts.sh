#!/bin/bash
# Certificate Generation Script for mTLS Lab
# This script generates all certificates needed for mutual TLS authentication

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  mTLS Certificate Generation Script${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# Create certs directory
CERTS_DIR="certs"
mkdir -p $CERTS_DIR
cd $CERTS_DIR

echo -e "${YELLOW}[1/5] Generating Root CA...${NC}"

# Generate Root CA private key
openssl genrsa -out ca.key 4096

# Generate Root CA certificate
openssl req -x509 -new -nodes -key ca.key -sha256 -days 3650 \
  -out ca.crt \
  -subj "/C=US/ST=Texas/L=Coppell/O=Azure mTLS Lab/OU=IT/CN=mTLS Root CA"

echo -e "${GREEN}✓ Root CA generated${NC}"

# Function to generate server certificate
generate_server_cert() {
    local HOST=$1
    local CN=$2
    local SHARED_CN=${3:-$CN}
    
    echo -e "${YELLOW}[Generating certificate for $HOST]${NC}"
    
    # Generate private key
    openssl genrsa -out ${HOST}.key 2048
    
    # Generate CSR using shared CN so all backends match the same probe hostname
    openssl req -new -key ${HOST}.key -out ${HOST}.csr \
      -subj "/C=US/ST=Texas/L=Coppell/O=Azure mTLS Lab/OU=Backend Servers/CN=${SHARED_CN}"
    
    # Create OpenSSL extension config
    cat > ${HOST}.ext << EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
subjectAltName = @alt_names
extendedKeyUsage = serverAuth

[alt_names]
DNS.1 = backend.azure.local
DNS.2 = ${CN}
DNS.3 = ${HOST}
DNS.4 = localhost
IP.1 = 127.0.0.1
EOF
    
    # Sign the certificate
    openssl x509 -req -in ${HOST}.csr -CA ca.crt -CAkey ca.key \
      -CAcreateserial -out ${HOST}.crt -days 825 -sha256 \
      -extfile ${HOST}.ext
    
    # Verify certificate
    openssl verify -CAfile ca.crt ${HOST}.crt

    # Build full chain file (leaf cert + CA) for nginx deployment
    cat ${HOST}.crt ca.crt > ${HOST}-chain.crt
    
    echo -e "${GREEN}✓ Certificate for $HOST generated and verified${NC}"
}

echo -e "${YELLOW}[2/5] Generating Host1 (Red) Server Certificate...${NC}"
generate_server_cert "host1" "host1.azure.local" "backend.azure.local"

echo -e "${YELLOW}[3/5] Generating Host2 (Blue) Server Certificate...${NC}"
generate_server_cert "host2" "host2.azure.local" "backend.azure.local"

echo -e "${YELLOW}[4/5] Generating Client Certificate for Application Gateway...${NC}"

# Generate client private key
openssl genrsa -out appgw-client.key 2048

# Generate client CSR
openssl req -new -key appgw-client.key -out appgw-client.csr \
  -subj "/C=US/ST=Texas/L=Coppell/O=Azure mTLS Lab/OU=Application Gateway/CN=AppGW Client"

# Create client extension config
cat > appgw-client.ext << EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
extendedKeyUsage = clientAuth
EOF

# Sign the client certificate
openssl x509 -req -in appgw-client.csr -CA ca.crt -CAkey ca.key \
  -CAcreateserial -out appgw-client.crt -days 825 -sha256 \
  -extfile appgw-client.ext

# Verify client certificate
openssl verify -CAfile ca.crt appgw-client.crt

echo -e "${GREEN}✓ Client certificate generated and verified${NC}"

echo -e "${YELLOW}[5/5] Creating PFX bundle for Application Gateway...${NC}"

# Create PFX file (PKCS#12) for Application Gateway SSL certificate
# Note: Using empty password for simplicity - in production, use a secure password
openssl pkcs12 -export -out appgw-ssl.pfx \
  -inkey appgw-client.key \
  -in appgw-client.crt \
  -certfile ca.crt \
  -passout pass:

echo -e "${GREEN}✓ PFX bundle created${NC}"

# Create a combined PEM file for the client certificate (for AppGW authentication)
cat appgw-client.crt appgw-client.key > appgw-client-full.pem

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Certificate Generation Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "Generated certificates:"
echo "  📁 Root CA:"
echo "     - ca.crt (Root Certificate)"
echo "     - ca.key (Root Private Key)"
echo ""
echo "  🔴 Host1 (Red Server):"
echo "     - host1.crt (Server Certificate)"
echo "     - host1.key (Server Private Key)"
echo ""
echo "  🔵 Host2 (Blue Server):"
echo "     - host2.crt (Server Certificate)"
echo "     - host2.key (Server Private Key)"
echo ""
echo "  🌐 Application Gateway:"
echo "     - appgw-client.crt (Client Certificate)"
echo "     - appgw-client.key (Client Private Key)"
echo "     - appgw-ssl.pfx (PFX Bundle)"
echo "     - appgw-client-full.pem (Combined PEM)"
echo ""

# Display certificate information
echo -e "${YELLOW}Root CA Information:${NC}"
openssl x509 -in ca.crt -noout -subject -dates
echo ""

cd ..
