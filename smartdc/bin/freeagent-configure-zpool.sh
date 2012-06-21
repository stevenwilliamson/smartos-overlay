#!/usr/bin/bash

PATH=/usr/sbin:/usr/bin
export PATH
. /lib/sdc/config.sh
load_sdc_sysinfo
load_sdc_config

sigexit()
{
  echo
  echo "System configuration has not been completed."
  echo "You must reboot to re-run system configuration."
  exit 0
}

create_dump()
{
    # Get avail zpool size - this assumes we're not using any space yet.
    base_size=`zfs get -H -p -o value available ${SYS_ZPOOL}`
    # Convert to MB
    base_size=`expr $base_size / 1000000`
    # Calculate 5% of that
    base_size=`expr $base_size / 20`
    # Cap it at 4GB
    [ ${base_size} -gt 4096 ] && base_size=4096

    # Create the dump zvol
    zfs create -V ${base_size}mb ${SYS_ZPOOL}/dump || \
      fatal "failed to create the dump zvol"
    dumpadm -d /dev/zvol/dsk/${SYS_ZPOOL}/dump
}

#
# Setup the persistent datasets on the zpool.
#
setup_datasets()
{
  datasets=$(zfs list -H -o name | xargs)
  
  if ! echo $datasets | grep dump > /dev/null; then
    printf "%-56s" "Making dump zvol... " 
    create_dump
    printf "%4s\n" "done" 
  fi

  if ! echo $datasets | grep ${CONFDS} > /dev/null; then
    printf "%-56s" "Initializing config dataset for zones... " 
    zfs create ${CONFDS} || fatal "failed to create the config dataset"
    chmod 755 /${CONFDS}
    cp -p /etc/zones/* /${CONFDS}
    zfs set mountpoint=legacy ${CONFDS}
    printf "%4s\n" "done" 
  fi

  if ! echo $datasets | grep ${USBKEYDS} > /dev/null; then
    printf "%-56s" "Creating config dataset... " 
    zfs create -o mountpoint=legacy ${USBKEYDS} || \
      fatal "failed to create the config dataset"
    mkdir /usbkey
    mount -F zfs ${USBKEYDS} /usbkey
    printf "%4s\n" "done" 
  fi

  if ! echo $datasets | grep ${COREDS} > /dev/null; then
    printf "%-56s" "Creating global cores dataset... " 
    zfs create -o quota=10g -o mountpoint=/${SYS_ZPOOL}/global/cores \
        -o compression=gzip ${COREDS} || \
        fatal "failed to create the cores dataset"
    printf "%4s\n" "done" 
  fi

  if ! echo $datasets | grep ${OPTDS} > /dev/null; then
    printf "%-56s" "Creating opt dataset... " 
    zfs create -o mountpoint=legacy ${OPTDS} || \
      fatal "failed to create the opt dataset"
    printf "%4s\n" "done" 
  fi

  if ! echo $datasets | grep ${VARDS} > /dev/null; then
    printf "%-56s" "Initializing var dataset... " 
    zfs create ${VARDS} || \
      fatal "failed to create the var dataset"
    chmod 755 /${VARDS}
    cd /var
    if ( ! find . -print | cpio -pdm /${VARDS} 2>/dev/null ); then
        fatal "failed to initialize the var directory"
    fi

    zfs set mountpoint=legacy ${VARDS}

    if ! echo $datasets | grep ${SWAPVOL} > /dev/null; then
          printf "%-56s" "Creating swap zvol... " 
          #
          # We cannot allow the swap size to be less than the size of DRAM, lest$
          # we run into the availrmem double accounting issue for locked$
          # anonymous memory that is backed by in-memory swap (which will$
          # severely and artificially limit VM tenancy).  We will therfore not$
          # create a swap device smaller than DRAM -- but we still allow for the$
          # configuration variable to account for actual consumed space by using$
          # it to set the refreservation on the swap volume if/when the$
          # specified size is smaller than DRAM.$
          #
          size=${SYSINFO_MiB_of_Memory}
          zfs create -V ${size}mb ${SWAPVOL}
          swap -a /dev/zvol/dsk/${SWAPVOL}
    fi
    printf "%4s\n" "done" 
  fi
}


create_zpool()
{
    disks=$1
    pool=zones

    # If the pool already exists, don't create it again.
    if /usr/sbin/zpool list -H -o name $pool; then
        return 0
    fi

    disk_count=$(echo "${disks}" | wc -w | tr -d ' ')
    printf "%-56s" "Creating pool $pool... " 

    # If no pool profile was provided, use a default based on the number of
    # devices in that pool.
    if [[ -z ${profile} ]]; then
        case ${disk_count} in
        0)
             fatal "no disks found, can't create zpool";;
        1)
             profile="";;
        2)
             profile=mirror;;
        *)
             profile=raidz;;
        esac
    fi

    zpool_args=""

    # When creating a mirrored pool, create a mirrored pair of devices out of
    # every two disks.
    if [[ ${profile} == "mirror" ]]; then
        ii=0
        for disk in ${disks}; do
            if [[ $(( $ii % 2 )) -eq 0 ]]; then
                  zpool_args="${zpool_args} ${profile}"
            fi
            zpool_args="${zpool_args} ${disk}"
            ii=$(($ii + 1))
        done
    else
        zpool_args="${profile} ${disks}"
    fi

    zpool create -f ${pool} ${zpool_args} || \
        fatal "failed to create pool ${pool}"
    zfs set atime=off ${pool} || \
        fatal "failed to set atime=off for pool ${pool}"

    printf "%4s\n" "done" 
}

create_zpools()
{
  devs=$1

  export SYS_ZPOOL="zones"
  create_zpool "$devs"
  sleep 5

  svccfg -s svc:/system/smartdc/init setprop config/zpool="zones"
  svccfg -s svc:/system/smartdc/init:default refresh

  export CONFDS=${SYS_ZPOOL}/config
  export COREDS=${SYS_ZPOOL}/cores
  export OPTDS=${SYS_ZPOOL}/opt
  export VARDS=${SYS_ZPOOL}/var
  export USBKEYDS=${SYS_ZPOOL}/usbkey
  export SWAPVOL=${SYS_ZPOOL}/swap
  
  setup_datasets
  #
  # Since there may be more than one storage pool on the system, put a
  # file with a certain name in the actual "system" pool.
  #
  touch /${SYS_ZPOOL}/.system_pool
}

trap sigexit SIGINT

export TERM=sun-color
export TERM=xterm-color
stty erase ^H

create_zpools $*

cp -rp /etc/ssh /usbkey/ssh
cp /usr/ds/etc/sources.list.sample /var/db/dsadm/sources.list

