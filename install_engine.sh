#!/bin/bash

# Get the directory of the script
SCRIPT_DIR=$(dirname "$0")

# Check if Docker is installed
  echo "   -----Checking if Docker is installed-----"

if ! command -v docker &> /dev/null; then
  sleep .5
  echo "   -----Docker not found, starting Docker installation-----"
  sleep .5
  # Add Docker's official GPG key:
  echo "   -----Adding Docker's official GPG key-----"
  sleep .5
  sudo apt-get update
  sudo apt-get install -y ca-certificates curl
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc

  # Add the repository to Apt sources:
  echo "   -----Adding Docker repository to apt sources-----"
  sleep .5
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
    sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
  sudo apt-get update

  echo "   -----Installing Docker-----"
  sleep .5
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  echo "   -----Docker Installation complete, starting Wowza Streaming Engine installation-----"
  sleep .5
else
  echo "   -----Docker found, installing Wowza Streaming Engine-----"
fi

# Check if jq is installed
if ! command -v jq &> /dev/null; then
  echo "   -----jq not found, installing jq-----"
  sudo apt-get install -y jq > /dev/null 2>&1
fi

# Pull the 10 most recent versions of Wowza Engine from Docker and list them
echo "
Fetching the 10 most recent versions of Wowza Engine..."
recent_versions=$(curl -s https://registry.hub.docker.com/v2/repositories/wowzamedia/wowza-streaming-engine-linux/tags | jq -r '.results[].name' | sort -r | head -n 10)

echo "$recent_versions"

# Prompt user for version of the engine
read -p "Enter the version of the engine you want to build from the list above: " engine_version

# Define the build directory
BUILD_DIR="$SCRIPT_DIR/dockerBuild"

if [ ! -d "$BUILD_DIR" ]; then
  mkdir -p "$BUILD_DIR"
fi

# Check if base directory exists, if not create it and prompt the user to add files
BASE_DIR="$BUILD_DIR/base"
if [ ! -d "$BASE_DIR" ]; then
  mkdir -p "$BASE_DIR"
fi
echo "
***
Please add/upload your .jks file to $BASE_DIR
***"
read -p "Press [Enter] to continue after uploading the files or type 'skip' to move to the next step: " user_input
if [ "$user_input" == "skip" ]; then
  read -p "Press [Enter] to continue after uploading the files..."
fi

  # List files found in the directory
  echo "Files found in $BASE_DIR:"
  ls -1 "$BASE_DIR"

  # Find the .jks file
    jks_file=$(ls "$BASE_DIR"/*.jks 2>/dev/null | head -n 1)
    if [ -z "$jks_file" ]; then
      echo "No .jks file found. Continuing to the next step."
    else
      jks_file=$(basename "$jks_file")
      read -p "Provide the domain for .jks file (e.g., myWowzaDomain.com): " jks_domain
      read -s -p "Please enter the .jks password (to establihs https connection to Wowza Manager): " jks_password
    fi

# Create tomcat.properties file for HTTPS access to Wowza Streaming Engine Manager if there is a .jks file
if [ -z "$jks_file" ]; then
cat <<EOL > "$BASE_DIR/tomcat.properties"
httpsPort=8090
httpsKeyStore=/usr/local/WowzaStreamingEngine/conf/${jks_file}
httpsKeyStorePassword=${jks_password}
#httpsKeyAlias=[key-alias]
EOL
fi

# Change directory to $BUILD_DIR/
cd "$BUILD_DIR"

# Create a Dockerfile
cat <<EOL > Dockerfile
FROM wowzamedia/wowza-streaming-engine-linux:${engine_version}

COPY /base/tomcat.properties /usr/local/WowzaStreamingEngine/manager/conf/
COPY /base/${jks_file} /usr/local/WowzaStreamingEngine/conf/

RUN apt update
RUN apt install nano

WORKDIR /usr/local/WowzaStreamingEngine/
EOL

# Build the Docker image from specified version
sudo docker build . -t wowza_engine:$engine_version

# Check if $BUILD_DIR/Engine/ directory exists, if not create it
if [ ! -d "$BUILD_DIR/Engine/" ]; then
  mkdir -p $BUILD_DIR/Engine/
fi

# Change directory to $BUILD_DIR/Engine
cd $BUILD_DIR/Engine

# Create .env file and prompt the user for input
read -p "Provide Wowza username: " WSE_MGR_USER
read -s -p "Provide Wowza password: " WSE_MGR_PASS
echo
read -p "Provide Wowza license key: " WSE_LIC
echo
cat <<EOL > .env
WSE_MGR_USER=${WSE_MGR_USER}
WSE_MGR_PASS=${WSE_MGR_PASS}
WSE_LIC=${WSE_LIC}
EOL

# Check if docker-compose.yml is already present, if not create it
cat <<EOL > docker-compose.yml
services:
  wowza:
    image: docker.io/library/wowza_engine:${engine_version}
    container_name: wse_${engine_version}
    restart: always
    ports:
      - "6970-7000:6970-7000/udp"
      - "443:443"
      - "1935:1935"
      - "554:554"
      - "8084-8090:8084-8090/tcp"
    volumes:
      - /home/ubuntu/DockerWSELogs:/usr/local/WowzaStreamingEngine/logs
      - /home/ubuntu/DockerWSEcontent:/usr/local/WowzaStreamingEngine/content
    entrypoint: /sbin/entrypoint.sh
    env_file: 
      - ./.env
    environment:
      - WSE_LIC=${WSE_LIC}
      - WSE_MGR_USER=${WSE_MGR_USER}
      - WSE_MGR_PASS=${WSE_MGR_PASS}
EOL

# Run docker compose up
sudo docker compose up -d

# Change directory to $BUILD_DIR/Engine
cd $BUILD_DIR/Engine

# Get the public IP address
public_ip=$(curl -s ifconfig.me)

# Print instructions to stop WSE and connect to Wowza Streaming Engine Manager
echo "
To stop WSE, type: sudo docker compose down
"
if [ -n "$jks_domain" ]; then
  echo "To connect to Wowza Streaming Engine Manager, go to: https://${jks_domain}:8090/enginemanager"
else
  echo "To connect to Wowza Streaming Engine Manager, go to: http://$public_ip:8088/enginemanager"
fi

# Change directory to $BUILD_DIR/Engine
cd $BUILD_DIR/Engine