#!/bin/bash
set -x

# You can set up a repo by creating a folder and updating reghome below. then run:
# 
# ./run_repo.sh setup <fqdn> [<altname> ....]
# ./run_repo.sh setup_user <user> <pass>
# ./run_repo.sh start
#
# The repo will then be running, you can push images to it, with:
#
#  docker pull nginx/nginx-ingress:1.4.6
#  docker tag nginx/nginx-ingress:1.4.6 <fqdn>:5000/nginx:1.4.6
#  docker login <fqdn>:5000
#  docker push <fqdn>:5000/nginx:1.4.6

# Set reghome to the folder in which you want your repo to store it's files.
reghome="{{ cicd.docker.home }}/registry"

setup() {

  # Create the directory structure
  mkdir -p ${reghome}/auth
  mkdir -p ${reghome}/certs
  mkdir -p ${reghome}/registry
  touch ${reghome}/auth/htpasswd

  # Setup the openssl config
  cat <<EOF | sed -re 's/^\s+//g' > ${reghome}/openssl.cnf
  HOME			= $reghome
  RANDFILE		= \$ENV::HOME/.rnd

  [ req ]
  default_bits		= 2048
  default_keyfile 	= privkey.pem
  distinguished_name	= req_distinguished_name
  x509_extensions	= v3_ca	# The extensions to add to the self signed cert
  string_mask = utf8only

  [ req_distinguished_name ]
  countryName			= Country Name (2 letter code)
  countryName_default		= GB
  countryName_min			= 2
  countryName_max			= 2
  stateOrProvinceName		= State or Province Name (full name)
  stateOrProvinceName_default	= London
  localityName			= Locatity Name (eg, city)
  localityNameDefault = London
  0.organizationName		= Organization Name (eg, company)
  0.organizationName_default	= NGINX Inc
  organizationalUnitName		= Organizational Unit Name (eg, section)
  organizationalUnitName_default	= SA-EMEA
  commonName			= Common Name (e.g. server FQDN or YOUR name)
  commonName_default		= _SUBJECT_COMMON_NAME_
  commonName_max			= 64
  emailAddress			= Email Address
  emailAddress_max		= 64
  
  [v3_ca]
  subjectKeyIdentifier=hash
  authorityKeyIdentifier=keyid:always,issuer
  basicConstraints = critical,CA:true

  [req]
  req_extensions = v3_req

  [ v3_req ]
  basicConstraints = CA:FALSE
  keyUsage = nonRepudiation, digitalSignature, keyEncipherment
  subjectAltName = @alt_names

  [alt_names]
EOF

  # Setup the common name and SubjAltNames based on args
  sed -i -e "s/_SUBJECT_COMMON_NAME_/$1/" ${reghome}/openssl.cnf
  index=0
  for dom in $*
  do
    index=$(( $index + 1 ))
    echo "DNS.${index} = ${dom}" >> ${reghome}/openssl.cnf
  done

  # Generate the certs
  openssl req -new -nodes -keyout ${reghome}/certs/domain.key \
    -config ${reghome}/openssl.cnf > ${reghome}/certs/domain.csr
  openssl req -x509 -in ${reghome}/certs/domain.csr -out ${reghome}/certs/domain.crt \
    -key ${reghome}/certs/domain.key -days 1001 -config ${reghome}/openssl.cnf -extensions 'v3_req'

  
  DIST=$(lsb_release -si)
  case $DIST in
    Ubuntu|Debian|LinuxMint)
      cp "${reghome}/certs/domain.crt" "/usr/local/share/ca-certificates/docker_$1.crt"
      update-ca-certificates
      ;;
    *)
      echo "Assuming RedHat"
      cp "${reghome}/certs/domain.crt" "/etc/pki/ca-trust/source/anchors/docker_$1.crt"
      update-ca-trust
      ;;
  esac

}

setup_user() {
  #echo "$1:$(openssl passwd -6 $2)" >> ${reghome}/auth/htpasswd
  docker run \
  --entrypoint htpasswd \
  registry:2 -Bbn $1 $2 > auth/htpasswd
}

print_help() {
  cat <<EOF

    Usage:

    $0 setup <fqdn> <alt name1> <alt name2> ...
    Initialises the repo structure in \$reghome ($reghome).

    $0 setup_user <user> [ <pass> ]
    Adds a user for access to push images to the repo

    $0 start
    Starts or restart the docker repository

EOF
}

cmd=$1
shift 
case $cmd in 

  start)
    echo "Removing old registry"
    docker stop registry
    docker ps -a | grep registry | grep Exit | awk '{ print "docker rm", $1 }' | bash

    echo "Starting new docker registry"
    docker run -d -p 5000:5000 --restart=always --name registry \
      -v ${reghome}/certs:/certs \
      -v ${reghome}/auth:/auth \
      -v ${reghome}/registry:/var/lib/registry \
      -e REGISTRY_AUTH=htpasswd \
      -e REGISTRY_AUTH_HTPASSWD_REALM=PrivateRepo \
      -e REGISTRY_AUTH_HTPASSWD_PATH=/auth/htpasswd \
      -e REGISTRY_HTTP_TLS_CERTIFICATE=/certs/domain.crt \
      -e REGISTRY_HTTP_TLS_KEY=/certs/domain.key \
      registry:2
    ;;

  setup)
    setup $@
    ;;

  setup_user)
    setup_user $1 $2
    ;;

  *)
    print_help
    ;;
esac

