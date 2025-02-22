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
BUILD_DIR="$SCRIPT_DIR/DockerEngineInstaller"
mkdir -p "$BUILD_DIR"

# Check if base directory exists, if not create it and prompt the user to add files
BASE_DIR="$BUILD_DIR/base_files"
mkdir -p "$BASE_DIR"

## Create the Server.xml and VHost.xml files
echo "   -----Creating Server.xml and VHost.xml for SSL file-----"
# Create a temporary container from the image
sudo docker run -d --name temp_container --entrypoint /sbin/entrypoint.sh wowzamedia/wowza-streaming-engine-linux:${engine_version} > /dev/null

# Copy the VHost.xml file from the container to the host
sudo docker cp temp_container:/usr/local/WowzaStreamingEngine/conf/VHost.xml "$BASE_DIR/VHost.xml"
sudo docker cp temp_container:/usr/local/WowzaStreamingEngine/conf/Server.xml "$BASE_DIR/Server.xml"

# Remove the temporary container
sudo docker rm -f temp_container > /dev/null

# Function to scan for .jks file
check_for_jks() {
  echo "Files found in $BASE_DIR:"
  ls -1 "$BASE_DIR"

  # Find the .jks file
  jks_file=$(ls "$BASE_DIR"/*.jks 2>/dev/null | head -n 1)
  if [ -z "$jks_file" ]; then
    echo "No .jks file found."
    upload_jks
  else
    jks_file=$(basename "$jks_file")
    read -p "A .jks file ($jks_file) was detected. Do you want to use this file? (y/n): " use_detected_jks
    case $use_detected_jks in
      [Yy]* )
        ssl_config
        ;;
      [Nn]* )
        upload_jks
        ;;
      * )
        echo "Please answer yes or no."
        check_for_jks
        ;;
    esac
  fi
}

# Function to configure SSL
ssl_config() {
  read -p "Provide the domain for .jks file (e.g., myWowzaDomain.com): " jks_domain
  read -s -p "Please enter the .jks password (to establish https connection to Wowza Manager): " jks_password
  echo

  # Setup Engine to use SSL for streaming and Manager access #
  # Create the tomcat.properties file
  echo "   -----Creating tomcat.properties file-----"
  cat <<EOL > "$BASE_DIR/tomcat.properties"
httpsPort=8090
httpsKeyStore=/usr/local/WowzaStreamingEngine/conf/${jks_file}
httpsKeyStorePassword=${jks_password}
#httpsKeyAlias=[key-alias]
EOL

  # Change the <Port> line to have only 1935,554 ports
  sed -i 's|<Port>1935,80,443,554</Port>|<Port>1935,554</Port>|' "$BASE_DIR/VHost.xml"
  
  # Edit the VHost.xml file to include the new HostPort block with the JKS and password information
  sed -i '/<\/HostPortList>/i \
  <HostPort>\
      <Name>Autoconfig SSL Streaming</Name>\
      <Type>Streaming</Type>\
      <ProcessorCount>\${com.wowza.wms.TuningAuto}</ProcessorCount>\
      <IpAddress>*</IpAddress>\
      <Port>443</Port>\
      <HTTPIdent2Response></HTTPIdent2Response>\
      <SSLConfig>\
          <KeyStorePath>/usr/local/WowzaStreamingEngine/conf/'${jks_file}'</KeyStorePath>\
          <KeyStorePassword>'${jks_password}'</KeyStorePassword>\
          <KeyStoreType>JKS</KeyStoreType>\
          <DomainToKeyStoreMapPath></DomainToKeyStoreMapPath>\
          <SSLProtocol>TLS</SSLProtocol>\
          <Algorithm>SunX509</Algorithm>\
          <CipherSuites></CipherSuites>\
          <Protocols></Protocols>\
          <AllowHttp2>true</AllowHttp2>\
      </SSLConfig>\
      <SocketConfiguration>\
          <ReuseAddress>true</ReuseAddress>\
          <ReceiveBufferSize>65000</ReceiveBufferSize>\
          <ReadBufferSize>65000</ReceiveBufferSize>\
          <SendBufferSize>65000</SendBufferSize>\
          <KeepAlive>true</KeepAlive>\
          <AcceptorBackLog>100</AcceptorBackLog>\
      </SocketConfiguration>\
      <HTTPStreamerAdapterIDs>cupertinostreaming,smoothstreaming,sanjosestreaming,dvrchunkstreaming,mpegdashstreaming</HTTPStreamerAdapterIDs>\
      <HTTPProviders>\
          <HTTPProvider>\
              <BaseClass>com.wowza.wms.http.HTTPCrossdomain</BaseClass>\
              <RequestFilters>*crossdomain.xml</RequestFilters>\
              <AuthenticationMethod>none</AuthenticationMethod>\
          </HTTPProvider>\
          <HTTPProvider>\
              <BaseClass>com.wowza.wms.http.HTTPClientAccessPolicy</BaseClass>\
              <RequestFilters>*clientaccesspolicy.xml</RequestFilters>\
              <AuthenticationMethod>none</AuthenticationMethod>\
          </HTTPProvider>\
          <HTTPProvider>\
              <BaseClass>com.wowza.wms.http.HTTPProviderMediaList</BaseClass>\
              <RequestFilters>*jwplayer.rss|*jwplayer.smil|*medialist.smil|*manifest-rtmp.f4m</RequestFilters>\
              <AuthenticationMethod>none</AuthenticationMethod>\
          </HTTPProvider>\
          <HTTPProvider>\
              <BaseClass>com.wowza.wms.webrtc.http.HTTPWebRTCExchangeSessionInfo</BaseClass>\
              <RequestFilters>*webrtc-session.json</RequestFilters>\
              <AuthenticationMethod>none</AuthenticationMethod>\
          </HTTPProvider>\
          <HTTPProvider>\
              <BaseClass>com.wowza.wms.http.HTTPServerVersion</BaseClass>\
              <RequestFilters>*ServerVersion</RequestFilters>\
              <AuthenticationMethod>none</AuthenticationMethod>\
          </HTTPProvider>\
      </HTTPProviders>\
  </HostPort>' "$BASE_DIR/VHost.xml"

  # Edit the VHost.xml file to include the new TestPlayer block with the jks_domain
  sed -i '/<\/Manager>/i \
  <TestPlayer>\
      <IpAddress>'${jks_domain}'</IpAddress>\
      <Port>443</Port>\
      <SSLEnable>true</SSLEnable>\
  </TestPlayer>' "$BASE_DIR/VHost.xml"
  
  # Edit the Server.xml file to include the JKS and password information
  sed -i 's|<Enable>false</Enable>|<Enable>true</Enable>|' "$BASE_DIR/Server.xml"
  sed -i 's|<KeyStorePath></KeyStorePath>|<KeyStorePath>/usr/local/WowzaStreamingEngine/conf/'${jks_file}'</KeyStorePath>|' "$BASE_DIR/Server.xml"
  sed -i 's|<KeyStorePassword></KeyStorePassword>|<KeyStorePassword>'${jks_password}'</KeyStorePassword>|' "$BASE_DIR/Server.xml"
  sed -i 's|<IPWhiteList>127.0.0.1</IPWhiteList>|<IPWhiteList>*</IPWhiteList>|' "$BASE_DIR/Server.xml"
}

# Function to upload .jks file
upload_jks() {
  read -p "Do you want to upload a .jks file? (y/n): " upload_jks
  case $upload_jks in
    [Yy]* )
      while true; do
        read -p "Press [Enter] to continue after uploading the .jks file to $BASE_DIR..." 

        # Find the .jks file
        jks_file=$(ls "$BASE_DIR"/*.jks 2>/dev/null | head -n 1)
        if [ -z "$jks_file" ]; then
          read -p "No .jks file found. Would you like to upload again? (y/n): " upload_again
          case $upload_again in
            [Yy]* )
              read -p "Press [Enter] to continue after uploading the files..."
              ;;
            [Nn]* )
              echo "You chose not to add a .jks file. Moving on to tuning."
              return 1
              ;;
            * )
              echo "Please answer yes or no."
              ;;
          esac
        else
          check_for_jks
          return 0
        fi
      done
      ;;
    [Nn]* )
      echo "You chose not to add a .jks file. Moving on to tuning."
      return 1
      ;;
    * )
      echo "Please answer yes or no."
      upload_jks
      ;;
  esac
}

# Handle JKS file detection and setup
check_for_jks

# Server Tuning #
echo "   -----Tuning Network Sockets and Server Threads-----"
# Change ReceiveBufferSize and SendBufferSize values to 0 for <NetConnections> and <MediaCasters>
sed -i 's|<ReceiveBufferSize>.*</ReceiveBufferSize>|<ReceiveBufferSize>0</ReceiveBufferSize>|g' "$BASE_DIR/VHost.xml"
sed -i 's|<SendBufferSize>.*</SendBufferSize>|<SendBufferSize>0</SendBufferSize>|g' "$BASE_DIR/VHost.xml"

# Check CPU thread count
cpu_thread_count=$(nproc)

# Calculate pool sizes with limits
handler_pool_size=$((cpu_thread_count * 60))
transport_pool_size=$((cpu_thread_count * 40))

# Apply limits
if [ "$handler_pool_size" -gt 4096 ]; then
  handler_pool_size=4096
fi

if [ "$transport_pool_size" -gt 4096 ]; then
  transport_pool_size=4096
fi

# Update Server.xml with new pool sizes
sed -i 's|<HandlerThreadPool>.*</HandlerThreadPool>|<HandlerThreadPool><PoolSize>'"$handler_pool_size"'</PoolSize></HandlerThreadPool>|' "$BASE_DIR/Server.xml"
sed -i 's|<TransportThreadPool>.*</TransportThreadPool>|<TransportThreadPool><PoolSize>'"$transport_pool_size"'</PoolSize></TransportThreadPool>|' "$BASE_DIR/Server.xml"

# Configure Demo live stream
read -p "Do you want to add a demo live stream on Engine? (y/n): " demo_stream
if [ "$demo_stream" = "y" ]; then
  echo "   -----Adding demo live stream myStream to the Engine-----"
  # Create a demo live stream
  sed -i '/<\/ServerListeners>/i \
            <ServerListener>\
              <BaseClass>com.wowza.wms.module.ServerListenerStreamDemoPublisher</BaseClass>\
            </ServerListener>' "$BASE_DIR/Server.xml"
  
  # Find the line number of the closing </Properties> tag directly above the closing </Server> tag
  line_number=$(awk '/<\/Properties>/ {p=NR} /<\/Server>/ && p {print p; exit}' "$BASE_DIR/Server.xml")

  # Insert the new property at the found line number
  if [ -n "$line_number" ]; then
    sed -i "${line_number}i <Property>\n<Name>streamDemoPublisherConfig</Name>\n<Value>appName=live,srcStream=sample.mp4,dstStream=myStream,sendOnMetadata=true</Value>\n<Type>String</Type>\n</Property>" "$BASE_DIR/Server.xml"
  fi
fi

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
if [ -n "$jks_file" ] && [ -f "$BASE_DIR/$jks_file" ]; then
  echo "COPY base_files/${jks_file} /usr/local/WowzaStreamingEngine/conf/" >> Dockerfile
  echo "RUN chown wowza:wowza /usr/local/WowzaStreamingEngine/conf/${jks_file}" >> Dockerfile
fi

if [ -f "$BASE_DIR/tomcat.properties" ]; then
  echo "COPY base_files/tomcat.properties /usr/local/WowzaStreamingEngine/manager/conf/" >> Dockerfile
  echo "RUN chown wowza:wowza /usr/local/WowzaStreamingEngine/manager/conf/tomcat.properties" >> Dockerfile
fi

if [ -f "$BASE_DIR/Server.xml" ]; then
  echo "COPY base_files/Server.xml /usr/local/WowzaStreamingEngine/conf/" >> Dockerfile
  echo "RUN chown wowza:wowza /usr/local/WowzaStreamingEngine/conf/Server.xml" >> Dockerfile
fi

if [ -f "$BASE_DIR/VHost.xml" ]; then
  echo "COPY base_files/VHost.xml /usr/local/WowzaStreamingEngine/conf/" >> Dockerfile
  echo "RUN chown wowza:wowza /usr/local/WowzaStreamingEngine/conf/VHost.xml" >> Dockerfile
fi

# Build the Docker image from specified version
sudo docker build . -t wowza_engine:$engine_version

# Check if $COMPOSE_DIR directory exists, if not create it
COMPOSE_DIR="$BUILD_DIR/EngineCompose"
mkdir -p "$COMPOSE_DIR"

# Change directory to $COMPOSE_DIR
cd "$COMPOSE_DIR"

# Prompt user for Wowza Streaming Engine Manager credentials and license key
read -p "Provide Wowza username: " WSE_MGR_USER
read -s -p "Provide Wowza password: " WSE_MGR_PASS
echo
read -p "Provide Wowza license key: " WSE_LIC
echo

# Create .env file
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
echo "Running docker compose up..."
sudo docker compose up -d

# Wait for the services to start and print logs
echo "Waiting for services to start..."
sleep 3  # Adjust the sleep time as needed

echo "Printing docker compose logs..."
sudo docker compose logs

# Clean up the install directory
echo "Cleaning up the install directory..."

# Clean up the install directory
if [ -f "$BASE_DIR/VHost.xml" ]; then
  sudo rm "$BASE_DIR/VHost.xml"
fi

if [ -f "$BASE_DIR/Server.xml" ]; then
  sudo rm "$BASE_DIR/Server.xml"
fi

if [ -f "$BUILD_DIR/Dockerfile" ]; then
  sudo rm "$BUILD_DIR/Dockerfile"
fi

if [ -f "$BASE_DIR/tomcat.properties" ]; then
  sudo rm "$BASE_DIR/tomcat.properties"
fi

# Get the public IP address
public_ip=$(curl -s ifconfig.me)

# Get the private IP address
private_ip=$(ip addr show | grep 'inet ' | grep -v 127.0.0.1 | awk '{print $2}' | cut -d/ -f1 | head -n 1)

# Print instructions to stop WSE and connect to Wowza Streaming Engine Manager
echo "
To stop WSE, type: sudo docker compose -f $COMPOSE_DIR/docker-compose.yml down

"
echo "
Check $BUILD_DIR for Engine Logs and contents directories

"
if [ -n "$jks_domain" ]; then
  echo "To connect to Wowza Streaming Engine Manager over SSL, go to: https://${jks_domain}:8090/enginemanager"
else
  echo "To connect to Wowza Streaming Engine Manager via public IP, go to: http://$public_ip:8088/enginemanager"
  echo "To connect to Wowza Streaming Engine Manager via private IP, go to: http://$private_ip:8088/enginemanager"
fi
