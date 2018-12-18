#!/bin/bash -e
SCRIPT_DIR=$(cd $(dirname $0); /bin/pwd)

JENKINS_SLAVE_JAR_MD5="$1"
WORKSPACE="$2"
DOCKER_IMG_HOST="$3"
CLEANUP_WORKSPACE="$4"
if [ "X$WORKSPACE" = "X" ] ; then echo DATA_ERROR="Missing workspace directory." ;  exit 1; fi
if [ "${CLEANUP_WORKSPACE}" = "cleanup" ] ; then rm -rf $WORKSPACE ; fi
mkdir -p $WORKSPACE/tmp $WORKSPACE/workspace
rm -f $WORKSPACE/cmsos

echo "DATA_SHELL=${SHELL}"

slave_jar=false
if [ -e $WORKSPACE/slave.jar ] ; then
  if [ "$(md5sum $WORKSPACE/slave.jar | sed 's| .*||')" = "$JENKINS_SLAVE_JAR_MD5" ] ; then
    slave_jar=true
  else
    rm -f $WORKSPACE/slave.jar
  fi
fi
echo "DATA_SLAVE_JAR=${slave_jar}"

SLAVE_LABELS=""
arch=$(uname -m)
HOST_ARCH=""
if [ "$arch" = "aarch64" ] ; then
  HOST_ARCH=arm$(cat /proc/cpuinfo 2> /dev/null | grep 'CPU architectur' | sed 's|.*: *||' | tail -1)
elif [ "$arch" = "x86_64" ] ; then
  arch="amd64"
  HOST_ARCH=$(cat /proc/cpuinfo 2> /dev/null | grep vendor_id | sed 's|.*: *||' | tail -1)
fi
echo "DATA_HOST_ARCH=${HOST_ARCH}"
SLAVE_LABELS="${SLAVE_LABELS} ${arch} ${HOST_ARCH}"

DOCKER=""
if docker --version >/dev/null 2>&1 ; then
  if [ $(id -Gn 2>/dev/null | grep docker | wc -l) -gt 0 ] ; then DOCKER="docker" ; fi
fi
echo "DATA_DOCKER=${DOCKER}"
SLAVE_LABELS="${SLAVE_LABELS} ${DOCKER}"

SINGULARITY=""
if singularity --version >/dev/null 2>&1 ; then SINGULARITY="singularity" ;fi
echo "DATA_SINGULARITY=${SINGULARITY}"
SLAVE_LABELS="${SLAVE_LABELS} ${SINGULARITY}"

if [ "${DOCKER}${SINGULARITY}" != "" ] && [ "$DOCKER_IMG_HOST" != "" ] ; then
  os=$(echo $DOCKER_IMG_HOST | sed 's|:.*||;s|.*/||;s|-.*||')
  SLAVE_LABELS="${SLAVE_LABELS} ${os}"
  if [ "$os" = "cc7" ] ; then os="slc7" ; fi
  HOST_CMS_ARCH=${os}_${arch}
else
  rm -f $WORKSPACE/cmsos
  if wget --help >/dev/null 2>&1 ; then
    wget -q -O  $WORKSPACE/cmsos https://raw.githubusercontent.com/cms-sw/cmsdist/master/cmsos.file
  else
    curl -s -k -L -o $WORKSPACE/cmsos https://raw.githubusercontent.com/cms-sw/cmsdist/master/cmsos.file
  fi
  chmod +x $WORKSPACE/cmsos
  HOST_CMS_ARCH=$($WORKSPACE/cmsos 2>/dev/null)
fi
echo "DATA_HOST_CMS_ARCH=${HOST_CMS_ARCH}"
SLAVE_LABELS="${SLAVE_LABELS} ${HOST_CMS_ARCH} $(echo ${HOST_CMS_ARCH} | tr _ ' ')"

echo "DATA_REMOTE_USER_ID=$(id -u)"

let WORKSPACE_SIZE="$(df -k ${WORKSPACE} | tail -1 | tr ' ' '\n' | grep -v '^$' | tail -3 | head -1)/(1024*1024)"
echo "DATA_WORKSPACE_SIZE=${WORKSPACE_SIZE}"

JENKINS_SLAVE_SETUP=false
if [ -f ~/.jenkins-slave-setup ] ; then JENKINS_SLAVE_SETUP=true ; fi
echo "DATA_JENKINS_SLAVE_SETUP=${JENKINS_SLAVE_SETUP}"

val=$(nproc)
echo "DATA_CPUS=${val}"
SLAVE_LABELS="${SLAVE_LABELS} cpu-${val} cpu-tiny"
for t in 2:small 4:medium 8:large 16:xlarge 24:x2large 32:x3large 64:huge; do
  c=$(echo $t | sed 's|:.*||')
  if [ $val -gt $c ] ; then SLAVE_LABELS="${SLAVE_LABELS} cpu-$(echo $t | sed 's|.*:||')" ; fi
done

CPU_VECTOR_SET=$(cat /proc/cpuinfo | grep '^flags' | tail -1 | tr ' ' '\n' | grep '^sss*e\|^avx' | tr '\n' ' ')
echo "DATA_CPU_VECTOR_SET=${CPU_VECTOR_SET}"SINGULARITY
for is in ${CPU_VECTOR_SET} ; do SLAVE_LABELS="${SLAVE_LABELS} is-${is}" ; done

if [ -f /proc/driver/nvidia/version ]; then
  NVIDIA_VERSION=`cat /proc/driver/nvidia/version | sed -ne's/.*Kernel Module *\([0-9.]\+\).*/\1/p'`
else 
  # check if a kernel module is available, even if not currently loaded (e.g. for an OPTIMUS system)
  # if there are multiple modules, pick the newest one
  NVIDIA_MODULE=`modprobe -q -R nvidia 2>/dev/null || true`
  if [ "$NVIDIA_MODULE" ]; then
    NVIDIA_VERSION=`modinfo "$NVIDIA_MODULE" | grep '^version:' | sed 's|.*:\s*||;s|\s*$||'`
  fi
fi
echo "DATA_NVIDIA_VERSION=$NVIDIA_VERSION"
if [ "$NVIDIA_VERSION" ]; then SLAVE_LABELS="${SLAVE_LABELS} nvidia nvidia-$NVIDIA_VERSION" ; fi

if [ $(hostname | grep '^lxplus' | wc -l) -gt 0 ] ; then
  hname=$(hostname -s)
  case ${HOST_CMS_ARCH} in
    slc6_*) lxplus_type="lxplus6";;
    slc7_*) lxplus_type="lxplus7";;
  esac
  if [ "${CLEANUP_WORKSPACE}" != "cleanup" ] ; then
    SLAVE_LABELS="$hname lxplus-scripts ${lxplus_type}-scripts"
  else 
    SLAVE_LABELS="$hname lxplus ${lxplus_type} ${HOST_CMS_ARCH}-lxplus ${HOST_CMS_ARCH}-${lxplus_type} ${HOST_ARCH}"
  fi
fi

echo "DATA_SLAVE_LABELS=$(echo ${SLAVE_LABELS} | tr ' ' '\n' | grep -v '^$' | sort | uniq | tr '\n' ' ')"
