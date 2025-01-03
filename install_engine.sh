#!/bin/bash

# Get the directory of the script
SCRIPT_DIR=$(realpath $(dirname "$0"))

# Function to install Docker
install_docker() {
  echo "   -----Docker not found, starting Docker installation-----"
  sudo apt-get update
  sudo apt-get install -y ca-certificates curl
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
  sudo apt-get update
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  echo "   -----Docker Installation complete-----"
}

# Function to install jq
install_jq() {
  echo "   -----jq not found, installing jq-----"
  sudo apt-get install -y jq > /dev/null 2>&1
}

# Check if Docker is installed
echo "   -----Checking if Docker is installed-----"
if ! command -v docker &> /dev/null; then
  install_docker
else
  echo "   -----Docker found-----"
fi

# Check if jq is installed
if ! command -v jq &> /dev/null; then
  install_jq
fi

# Fetch all available versions of Wowza Engine from Docker
all_versions=""
url="https://registry.hub.docker.com/v2/repositories/wowzamedia/wowza-streaming-engine-linux/tags"
while [ -n "$url" ]; do
  response=$(curl -s "$url")
  tags=$(echo "$response" | jq -r '.results[] | "\(.name) \(.last_updated)"')
  all_versions="$all_versions"$'\n'"$tags"
  url=$(echo "$response" | jq -r '.next')
done

# Sort versions by date released
sorted_versions=$(echo "$all_versions" | sort -k2 -r)

# Remove the date field and display only the version names
sorted_versions=$(echo "$sorted_versions" | awk '{print $1}')
echo "All available versions sorted by date released:"
echo "$sorted_versions"

# Prompt user for version of the engine and verify if it exists
while true; do
  read -p "Enter the version of the engine you want to build from the list above: " engine_version
  if echo "$sorted_versions" | grep -q "^${engine_version}$"; then
    break
  else
    echo "Error: The specified version ${engine_version} does not exist. Please enter a valid version from the list below:"
    echo "$sorted_versions"
  fi
done

# Define the build directory
BUILD_DIR="$SCRIPT_DIR/dockerBuild"
mkdir -p "$BUILD_DIR"

# Check if base directory exists, if not create it and prompt the user to add files
BASE_DIR="$BUILD_DIR/base"
mkdir -p "$BASE_DIR"

while true; do
  read -p "Do you want to add your .jks file to $BASE_DIR? (y/n): " user_input

  case $user_input in
    [Yy]* )
      read -p "Press [Enter] to continue after uploading the files..." 
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
        read -s -p "Please enter the .jks password (to establish https connection to Wowza Manager): " jks_password
        echo
        # Create the tomcat.properties file
        cat <<EOL > "$BASE_DIR/tomcat.properties"
httpsPort=8090
httpsKeyStore=/usr/local/WowzaStreamingEngine/conf/${jks_file}
httpsKeyStorePassword=${jks_password}
#httpsKeyAlias=[key-alias]
EOL
      fi
      break
      ;;
    [Nn]* )
      echo "You chose not to add a .jks file."
      break
      ;;
    * )
      echo "Please answer yes or no."
      ;;
  esac
done

# Change directory to $BUILD_DIR/
cd "$BUILD_DIR"

# Create a Dockerfile
cat <<EOL > Dockerfile
FROM wowzamedia/wowza-streaming-engine-linux:${engine_version}

RUN apt update
RUN apt install nano

WORKDIR /usr/local/WowzaStreamingEngine/
EOL

# Append COPY commands if the files exist
if [ -f "$BASE_DIR/tomcat.properties" ]; then
  echo "COPY /base/tomcat.properties /usr/local/WowzaStreamingEngine/manager/conf/" >> Dockerfile
fi

if [ -n "$jks_file" ] && [ -f "$BASE_DIR/$jks_file" ]; then
  echo "COPY /base/${jks_file} /usr/local/WowzaStreamingEngine/conf/" >> Dockerfile
fi

# Build the Docker image from specified version
sudo docker build . -t wowza_engine:$engine_version

# Check if $BUILD_DIR/Engine/ directory exists, if not create it
mkdir -p "$BUILD_DIR/Engine/"

# Change directory to $BUILD_DIR/Engine
cd "$BUILD_DIR/Engine"

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

# Create docker-compose.yml
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
      - $BUILD_DIR/DockerWSELogs:/usr/local/WowzaStreamingEngine/logs
      - $BUILD_DIR/DockerWSEcontent:/usr/local/WowzaStreamingEngine/content
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
cd "$BUILD_DIR/Engine"

# Get the public IP address
public_ip=$(curl -s ifconfig.me)

# Get the private IP address
private_ip=$(ip addr show | grep 'inet ' | grep -v 127.0.0.1 | awk '{print $2}' | cut -d/ -f1 | head -n 1)

# Print instructions to stop WSE and connect to Wowza Streaming Engine Manager
echo "
To stop WSE, type: sudo docker compose down
"
if [ -n "$jks_domain" ]; then
  echo "To connect to Wowza Streaming Engine Manager over SSL, go to: https://${jks_domain}:8090/enginemanager"
else
  echo "To connect to Wowza Streaming Engine Manager via public IP, go to: http://$public_ip:8088/enginemanager"
  echo "To connect to Wowza Streaming Engine Manager via private IP, go to: http://$private_ip:8088/enginemanager"
fi

# Change directory to $BUILD_DIR/Engine
cd "$BUILD_DIR/Engine/"
