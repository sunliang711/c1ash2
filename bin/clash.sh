#!/bin/bash
if [ -z "${BASH_SOURCE}" ]; then
    this=${PWD}
else
    rpath="$(readlink ${BASH_SOURCE})"
    if [ -z "$rpath" ]; then
        rpath=${BASH_SOURCE}
    fi
    this="$(cd $(dirname $rpath) && pwd)"
fi

export PATH=$PATH:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

user="${SUDO_USER:-$(whoami)}"
home="$(eval echo ~$user)"

# export TERM=xterm-256color

# Use colors, but only if connected to a terminal, and that terminal
# supports them.
if which tput >/dev/null 2>&1; then
  ncolors=$(tput colors 2>/dev/null)
fi
if [ -t 1 ] && [ -n "$ncolors" ] && [ "$ncolors" -ge 8 ]; then
    RED="$(tput setaf 1)"
    GREEN="$(tput setaf 2)"
    YELLOW="$(tput setaf 3)"
    BLUE="$(tput setaf 4)"
    CYAN="$(tput setaf 5)"
    BOLD="$(tput bold)"
    NORMAL="$(tput sgr0)"
else
    RED=""
    GREEN=""
    YELLOW=""
    CYAN=""
    BLUE=""
    BOLD=""
    NORMAL=""
fi

_onlyLinux(){
    if [ $(uname) != "Linux" ];then
        _err "Only on linux"
        exit 1
    fi
}

_err(){
    echo "$*" >&2
}

_command_exists(){
    command -v "$@" > /dev/null 2>&1
}

rootID=0

_runAsRoot(){
    cmd="${*}"
    bash_c='bash -c'
    if [ "${EUID}" -ne "${rootID}" ];then
        if _command_exists sudo; then
            bash_c='sudo -E bash -c'
        elif _command_exists su; then
            bash_c='su -c'
        else
            cat >&2 <<-'EOF'
			Error: this installer needs the ability to run commands as root.
			We are unable to find either "sudo" or "su" available to make this happen.
			EOF
            exit 1
        fi
    fi
    # only output stderr
    (set -x; $bash_c "${cmd}")
}

function _insert_path(){
    if [ -z "$1" ];then
        return
    fi
    echo -e ${PATH//:/"\n"} | grep -c "^$1$" >/dev/null 2>&1 || export PATH=$1:$PATH
}

_run(){
    # only output stderr
    cmd="$*"
    (set -x; bash -c "${cmd}")
}

function _root(){
    if [ ${EUID} -ne ${rootID} ];then
        echo "Need run as root!"
        echo "Requires root privileges."
        exit 1
    fi
}

ed=vi
if _command_exists vim; then
    ed=vim
fi
if _command_exists nvim; then
    ed=nvim
fi
# use ENV: editor to override
if [ -n "${editor}" ];then
    ed=${editor}
fi
###############################################################################
# write your code below (just define function[s])
# function is hidden when begin with '_'
###############################################################################
binName=clash
root="$(cd ${this}/.. && pwd)"
etcDir="${root}/etc"
templateDir="${root}/template"
gatewayFile="${etcDir}/gateway"

case $(uname) in
    Linux)
        cmdStat=stat
        ;;
    Darwin)
        cmdStat='stat -x'
        ;;
esac
# logfile=/tmp/clash.log
# configFile=${this}/../config.yaml
# configExampleFile=${this}/../config-example.yaml

add(){
    local name=${1:?'missing config name(no extension)'}
    name=${name%.json}
    local gateway=${2}

    # exist?
    if [ -e ${etcDir}/$name ];then
        echo "${RED}Error: already exists${NORMAL}"
        exit 1
    fi

    set -e
    # create a subDir for this one
    local subDir="${root}/etc/${name}"
    _run "mkdir -p ${subDir}"
    # link Country.mmdb
    (cd ${subDir} && _run "ln -sf ../../Country.mmdb .")
    # copy a config file
    (cd ${subDir} && _run "cp ${templateDir}/config-example.yaml ${name}.yaml")

    ${ed} ${etcDir}/$name/${name}.yaml

    # service file
    case $(uname) in
        Darwin)
            sed -e "s|<NAME>|${name}|g" \
                -e "s|<CWD>|${subDir}|g" \
                -e "s|<EXE>|${root}/clash|g" \
                -e "s|<CONFIG>|${name}.yaml|g" \
                ${templateDir}/clash.plist > $home/Library/LaunchAgents/${name}.plist
        ;;
        Linux)
            local start_pre="${this}/clash.sh _start_pre ${name}"
            local start="${root}/clash -d . -f ${name}.yaml"
            local start_post="${this}/clash.sh _start_post ${name}"
            local stop_post="${this}/clash.sh _stop_post ${name}"
            sed -e "s|<START_PRE>|${start_pre}|g" \
                -e "s|<START>|${start}|g" \
                -e "s|<START_POST>|${start_post}|g" \
                -e "s|<STOP_POST>|${stop_post}|g" \
                -e "s|<USER>|root|g" \
                -e "s|<CWD>|${subDir}|g" \
                ${templateDir}/clash.service > /tmp/${name}.service
            _runAsRoot "mv /tmp/${name}.service /etc/systemd/system"
            _runAsRoot "systemctl daemon-reload"
            _runAsRoot "systemctl enable --now ${name}.service"
            # set transparent proxy gateway
            if [ "x${gateway}" = "x-g" ];then
                cat ${name} > ${gatewayFile}
            fi
        ;;
    esac
}

remove(){
    local name=${1:?'missing config name(no extension)'}
    name=${name%.json}

    local subDir="${root}/etc/${name}"

    if [ ! -e ${subDir} ];then
        echo "Error: not found runtime dir: ${subDir}"
        exit 1
    fi

    stop ${name}
    case $(uname) in
        Linux)
            _runAsRoot "/bin/rm -rf /etc/systemd/system/${name}.service"
            _runAsRoot "systemctl daemon-reload"
            ;;
        Darwin)
            _run "/bin/rm -rf $home/Library/LaunchAgents/${name}.plist"
            ;;
    esac

    _run "/bin/rm -rf ${subDir}"
}

_start_pre(){
    echo "_start_pre"
    local name=${1:?'missing config name(no extension)'}
    name=${name%.json}
    if [ ! -e ${root}/clash ];then
        echo "Error: not found clash executable!"
        exit 1
    fi
    local subDir="${root}/etc/${name}"

    if [ ! -e ${subDir} ];then
        echo "Error: not found runtime dir: ${subDir}"
        exit 1
    fi
}

_start_post(){
    echo "_start_post"
    local name=${1:?'missing config name(no extension)'}
    name=${name%.json}
    if [ -e ${gatewayFile} ];then
        local gatewayName="$(cat ${gatewayFile})"
        if [ ${name} = ${gatewayName} ];then
            echo "+ ${name} is gateway,set it..."
            _set ${name}
        fi
    fi
}

_stop_post(){
    echo "_stop_post"
    local name=${1:?'missing config name(no extension)'}
    name=${name%.json}
    if [ -e ${gatewayFile} ];then
        gatewayName="$(cat ${gatewayFile})"
        if [ ${name} = ${gatewayName} ];then
            echo "+ ${name} is gateway,clear it..."
            _clear ${name}
        fi
    fi
}

start(){
    local name=${1:?'missing config name(no extension)'}
    name=${name%.json}
    local subDir="${root}/etc/${name}"
    local configFile="${subDir}/${name}.yaml"

    if [ ! -e ${subDir} ];then
        echo "Error: not found runtime dir: ${subDir}"
        exit 1
    fi

    case $(uname) in
        Linux)
            _runAsRoot "systemctl start ${name}.service"
            ;;
        Darwin)
            launchctl load -w $home/Library/LaunchAgents/${name}.plist 2>/dev/null
            ;;
    esac

    echo "check status..."
    if status ${name} >/dev/null;then
        if [ $(uname) = "Darwin" ];then
            port=$(grep '^port:' $configFile | awk '{print $2}')
            if [ -n $port ];then
                echo "Set system http proxy: localhost:$port"
                echo "Set system https proxy: localhost:$port"
                bash ${root}/setMacProxy.sh http $port >/dev/null
                bash ${root}/setMacProxy.sh https $port >/dev/null
            else
                echo "${RED}Error${NORMAL}: get http port error."
            fi
        fi
        echo "OK: ${name} is running now."
    else
        echo "Error: ${name} is not running."
    fi
}

setgw(){
    _onlyLinux
    local name=${1:?'missing config name(no extension)'}
    name=${name%.json}
    local subDir="${root}/etc/${name}"
    if [ ! -e ${subDir} ];then
        echo "Error: not found runtime dir: ${subDir}"
        exit 1
    fi

    echo "Tip: set redir_port!!"
    echo ${name} > ${gatewayFile}

}

stop(){
    local name=${1:?'missing config name(no extension)'}
    name=${name%.json}
    local subDir="${root}/etc/${name}"

    if [ ! -e ${subDir} ];then
        echo "Error: not found runtime dir: ${subDir}"
        exit 1
    fi

    echo "stop clash ${name}..."
    case $(uname) in
        Linux)
            _runAsRoot systemctl stop ${name}.service
            ;;
        Darwin)
            launchctl unload -w $home/Library/LaunchAgents/${name}.plist 2>/dev/null
            bash ${root}/setMacProxy.sh unset
            ;;
    esac
}

_set(){
    echo "_set"
    local name=${1:?'missing config name(no extension)'}
    name=${name%.json}
    local subDir="${root}/etc/${name}"
    local configFile="${subDir}/${name}.yaml"

    local redir_port="$(perl -lne 'print $1 if /^\s*redir-port:\s*(\d+)/' ${configFile})"
    if [ -z "${redir_port}" ];then
        echo "Cannot find redir_port"
        exit 1
    fi
    echo "${green}Found redir_port: ${redir_port}${reset}"
    cmd="$(cat<<EOF
    iptables -t nat -N clash || { return 0; }
    iptables -t nat -A clash -d 0.0.0.0/8 -j RETURN
    iptables -t nat -A clash -d 10.0.0.0/8 -j RETURN
    iptables -t nat -A clash -d 127.0.0.0/8 -j RETURN
    iptables -t nat -A clash -d 169.254.0.0/16 -j RETURN
    iptables -t nat -A clash -d 172.16.0.0/12 -j RETURN
    iptables -t nat -A clash -d 192.168.0.0/16 -j RETURN
    iptables -t nat -A clash -d 224.0.0.0/4 -j RETURN
    iptables -t nat -A clash -d 240.0.0.0/4 -j RETURN
    iptables -t nat -A clash -p tcp -j REDIRECT --to-ports ${redir_port}
    iptables -t nat -A PREROUTING -p tcp -j clash

    ip rule add fwmark 1 table 100
    ip route add local default dev lo table 100
    iptables -t mangle -N clash
    iptables -t mangle -A clash -d 0.0.0.0/8 -j RETURN
    iptables -t mangle -A clash -d 10.0.0.0/8 -j RETURN
    iptables -t mangle -A clash -d 127.0.0.0/8 -j RETURN
    iptables -t mangle -A clash -d 169.254.0.0/16 -j RETURN
    iptables -t mangle -A clash -d 172.16.0.0/12 -j RETURN
    iptables -t mangle -A clash -d 192.168.0.0/16 -j RETURN
    iptables -t mangle -A clash -d 224.0.0.0/4 -j RETURN
    iptables -t mangle -A clash -d 240.0.0.0/4 -j RETURN
    iptables -t mangle -A clash -p udp -j TPROXY --on-port ${redir_port} --tproxy-mark 1
    iptables -t mangle -A PREROUTING -p udp -j clash
EOF
)"
    _runAsRoot "${cmd}"
}

_clear(){
    echo "_clear"
    cmd="$(cat<<EOF
    iptables -t nat -D PREROUTING -p tcp -j clash
    iptables -t nat -F clash
    iptables -t nat -X clash

    iptables -t mangle -D PREROUTING -p udp -j clash
    iptables -t mangle -F clash
    iptables -t mangle -X clash

    ip rule del fwmark 1 table 100
EOF
)"
    _runAsRoot "${cmd}"
}

config(){
    local name=${1:?'missing config name(no extension)'}
    name=${name%.json}
    local subDir="${root}/etc/${name}"

    if [ ! -e ${subDir} ];then
        echo "Error: not found runtime dir: ${subDir}"
        exit 1
    fi
    local configFile="${subDir}/${name}.yaml"
    mtime0="$(${cmdStat} $configFile | grep Modify)"
    $ed $configFile
    mtime1="$(${cmdStat} $configFile | grep Modify)"
    #配置文件被修改
    if [ "$mtime0" != "$mtime1" ];then
        #并且当前是运行状态，则重启服务
        if status ${name} >/dev/null;then
            echo "Config file changed,restart server"
            restart ${name}
        fi
    fi
}

restart(){
    local name=${1:?'missing config name(no extension)'}
    name=${name%.json}
    local subDir="${root}/etc/${name}"

    if [ ! -e ${subDir} ];then
        echo "Error: not found runtime dir: ${subDir}"
        exit 1
    fi
    stop ${name}
    start ${name}
}

list(){
    (cd ${etcDir} && find . -iname "*.yaml")
}

status(){
    local name=${1:?'missing config name(no extension)'}
    name=${name%.json}
    local subDir="${root}/etc/${name}"

    if [ ! -e ${subDir} ];then
        echo "Error: not found runtime dir: ${subDir}"
        exit 1
    fi
    local configFile="${subDir}/${name}.yaml"

    if ! ps aux | grep clash | grep -v grep | grep -q "${name}.yaml"; then
        echo "$name not running"
        return 1
    fi
    local port=$(grep '^port:' "${configFile}" 2>/dev/null | awk '{print $2}')
    echo "clash is running on port: $port"
    if curl -x http://localhost:$port ifconfig.me >/dev/null 2>&1; then
        echo "Working on port: ${port}"
    else
        echo "${name} is running,but not work"
    fi
}

log(){
    local name=${1:?'missing config name(no extension)'}
    name=${name%.json}
    local subDir="${root}/etc/${name}"

    if [ ! -e ${subDir} ];then
        echo "Error: not found runtime dir: ${subDir}"
        exit 1
    fi

    case $(uname) in
        Linux)
            sudo journalctl -u ${name}.service -f
            ;;
        Darwin)
            echo "Watching ${name}.log..."
            tail -f /tmp/${name}.log
            ;;
    esac
}

em(){
    $ed $0
}

###############################################################################
# write your code above
###############################################################################
function _help(){
    cd ${this}
    cat<<EOF2
Usage: $(basename $0) ${bold}CMD${reset}

${bold}CMD${reset}:
EOF2
    perl -lne 'print "\t$2" if /^\s*(function)?\s*(\S+)\s*\(\)\s*\{$/' $(basename ${BASH_SOURCE}) | perl -lne "print if /^\t[^_]/"
}

case "$1" in
     ""|-h|--help|help)
        _help
        ;;
    *)
        "$@"
esac
