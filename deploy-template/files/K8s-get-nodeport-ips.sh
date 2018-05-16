#!/bin/bash
#
# Copyright (c) 2018 Pulse Secure LLC.
#
# This is a sample plugin for Pulse Virtual Traffic Manager (vTM) Flexible
# Service Discovery.
#
# This script is designed to query K8s API for a specified Service (by name)
# and return a list of Node IPs where active pods for this service exist, along
# with the ephemeral port (NodePort) that forwards to these pods.
#
# = Input parameters =
# This script accepts the following input parameters:
#
#  -s <K8s Service Name> - specifies which K8s Service to query
# [-n <namespace>] - optional, service's namespace
# [-p <portname>] - when a Service has multiple ports, use this to select one
#  -c <kubeconfig file name> - name of kubeconfig file in Extras
# [-g ] - download jq 1.5 + kubectl v1.9.5 into vTM's Extras dir
#
# = Outputs =
# The script will return its output in accordance with Pulse vTM flexible Service
# Discovery mechanism spec. See https://www.pulsesecure.net/download/techpubs/current/1261/Pulse-vADC-Solutions/Pulse-Virtual-Traffic-Manager/18.1/ps-vtm-18.1-userguide.pdf for more details.
#
# Misc info
#
# kubectl latest for Linux:
# curl -LO https://storage.googleapis.com/kubernetes-release/release/$(curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)/bin/linux/amd64/kubectl
#
# logMsg uses "nnn: <message>" format, where "nnn" is sequential. If you end up
# adding or removing logMsg calls in this script, run the following command to re-apply
# the sequence (replace "_" with space after logMsg):
#
# perl -i -000pe 's/(logMsg_")(...)/$1 . sprintf("%03d", ++$n)/ge' K8s-get-nodeport-ips.sh
#

# Parameters and defaults
serviceName=""          # K8s Service name we'll be looking for
nameSpace="default"     # ..in this namespace
kubeConfFile=""         # File name in Extras of kubeconfig file w/creds to talk to K8s
getDeps="No"            # Whether to try downloading jq + kubectl
kcVer="v1.9.5"          # Kubernetes version to get kubectl for. v1.9.5 was
                        # + used for development
portName=""             # Name of Service's port to look up NodePort for

if [[ ! ${ZEUSHOME} && ${ZEUSHOME-_} ]]; then
    # $ZEUSHOME is unset! Let's make an unsafe assumption we're *not* on a VA. :)
    # export ZEUSHOME="/opt/zeus"       # VA default
    export ZEUSHOME="/usr/local/zeus"   # Docker image default
fi

workDir="${ZEUSHOME}/zxtm/internal/servicediscovery"
extrasDir="${ZEUSHOME}/zxtm/conf/extra"

# We'll upload jq and kubectl into Extras; this is the directory where they
# will end up. Let's add it to $PATH
#
export PATH=$PATH:${extrasDir}

# Variables involved in generating the output
outVersion="1"  # version
outCode="0"     # code
outError=""     # error
outIPs=( )      # array of IPs for nodes
outPort="80"    # port

missingTools=""                 # List of missing prerequisites
lockFile=""                     # File name of our lock file
lockDir="/tmp"                  # Where to create a lock file
scriptName=$(basename $0)       # Used for logging and lock file naming
tmpDir="/tmp"                   # Where to keep our temp files
outFile="${tmpDir}/outfile.$$"  # To keep command outputs in
errFile="${tmpDir}/errfile.$$"  # To keep command errors in

# Not strictly necessary, but.. :)
if [[ -d "${workDir}" ]]; then
    cd "${workDir}"
fi

logFile="/var/log/${scriptName}.log"
#logFile="./${scriptName}.log"

# Called on any "exit"
cleanup  () {
    if [[ "${lockFile}" != "" ]]; then
        rm -f "${lockFile}"
    fi
    rm -f "${outFile}" "${errFile}"
}

trap cleanup EXIT

# Parse flags
while getopts "c:s:n:p:g" opt; do
    case "$opt" in
        c)  kubeConfFile=${OPTARG}
            ;;
        s)  serviceName=${OPTARG}
            ;;
        n)  nameSpace=${OPTARG}
            ;;
        p)  portName=${OPTARG}
            ;;
        g)  getDeps="Yes"
            ;;
    esac
done

shift $((OPTIND-1))

[ "$1" = "--" ] && shift

# Make ${kubeConfig} variable after passing parameters
kubeConfig="${extrasDir}/${kubeConfFile}"

# Logging sub
logMsg () {
    ts=$(date -u +%FT%TZ)
    echo "$ts ${scriptName}[$$]: $*" >> $logFile
}

# Generate the response in JSON
# Yah, this is kinda ugly. :)
#
printOut() {
    myJSON="{}"

    # Base parameters - version and code
    #
    myJSON=$(jq \
        --arg key0 'version' \
        --arg value0 ${outVersion} \
        --arg key1 'code' \
        --arg value1 "${outCode}" \
        '. | .[$key0]=($value0|tonumber) | .[$key1]=($value1|tonumber)' \
        <<<"${myJSON}" \
    )

    # Add Error Message, if we have it.
    #
    if [[ "${outError}" != "" ]]; then
        myJSON=$(jq \
            --arg key0 'error' \
            --arg value0 "${outError}" \
            '. | .[$key0]=$value0' \
            <<<${myJSON} \
        )
    fi

    # Add nodes, if we have them
    #
    jqArgs=( )
    jqQuery=""
    # Only return nodes if outCode is set to success = 200
    if [[ ${#outIPs[*]} != "0" && "${outCode}" == "200" ]]; then
        for idx in "${!outIPs[@]}"; do
            jqArgs+=( --arg "value_a$idx" "${outIPs[$idx]}" )
            jqArgs+=( --arg "value_b$idx" "${outPort}" )
            jqQuery+=" ( .ip=\$value_a${idx}"
            jqQuery+=" | .port=(\$value_b${idx}|tonumber) ) "
            if (( $idx != ${#outIPs[*]}-1 )); then
                jqQuery+=","
            fi
        done
        myJSON=$(jq \
            "${jqArgs[@]}" \
            ". + ( {} | .nodes=[ $jqQuery ] )" \
            <<<"${myJSON}" \
        )
    fi
    echo ${myJSON}
}

# Check prerequisites
#
checkPrerequisites () {
    # Check for curl
    #
    which curl > /dev/null
    if [[ $? != 0 ]]; then
        missingTools+=" curl"
    fi
    # We need curl to download jq/kubectl
    #
    if [[ "${missingTools}" != "" && "${getDeps}" = "Yes" ]]; then
        apt-get update > /dev/null 2>&1 \
        && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates curl > /dev/null 2>&1 \
        && apt-get autoremove --purge > /dev/null 2>&1
        if [[ $? != 0 ]]; then
            echo "{\"version\":1, \"code\":400, \"error\":\"Failed installing curl; please install by hand before retrying.\"}"
            exit 1
        else
            missingTools=""
        fi
    fi

    # Check for jq
    #
    jqExtra="${extrasDir}/jq"

    # If we've uploaded jq via extra and it hasn't +x on
    if [[ -s "${jqExtra}" && ! -x "${jqExtra}" ]]; then
        chmod +x "${jqExtra}"
    fi

    # Did we ask to download via parameter?
    if [[ ! -s "${jqExtra}" && "${getDeps}" = "Yes" ]]; then
        cd /tmp
        curl -s -LO https://github.com/stedolan/jq/releases/download/jq-1.5/jq-linux64
        if [[ -s jq-linux64 ]]; then
            cat jq-linux64 > "${jqExtra}" && chmod +x "${jqExtra}"
        fi
        rm -f jq-linux64
        cd - > /dev/null 2>&1
    fi
    which jq > /dev/null
    if [[ $? != 0 ]]; then
        missingTools+=" jq"
    fi

    # Check for kubectl
    #
    kcExtra="${extrasDir}/kubectl"

    # If we've uploaded kubectl via extra and it hasn't +x on
    if [[ -s "${kcExtra}" && ! -x "${kcExtra}" ]]; then
        chmod +x "${kcExtra}"
    fi

    # Did we ask to download via parameter?
    if [[ ! -s "${kcExtra}" && "${getDeps}" = "Yes" ]]; then
        cd /tmp
        curl -s -LO https://storage.googleapis.com/kubernetes-release/release/${kcVer}/bin/linux/amd64/kubectl
        if [[ -s kubectl ]]; then
            cat kubectl > "${kcExtra}" && chmod +x "${kcExtra}"
        fi
        rm -f kubectl
        cd - > /dev/null 2>&1
    fi
    which kubectl > /dev/null
    if [[ $? != 0 ]]; then
        missingTools+=" kubectl"
    fi

    # Anything missing? Error out ("by hand"), and exit.
    #
    if [[ "${missingTools}" != "" ]]; then
        echo "{\"version\":1, \"code\":400, \"error\":\"Prerequisite tool(s) missing:${missingTools}\"}"
        exit 1
    fi
    #
    if [[ ! -s "${kubeConfig}" ]]; then
        echo "{\"version\":1, \"code\":400, \"error\":\"Specified kubeconfig file is empty of missing: ${kubeConfig}\"}"
        exit 1
    fi
}

# Check if another copy of this script is already running
#
checkLock() {
    # Compose lock file name. First, base string, so we can check
    # if other instance of this script is already running.
    # This sub assumes that the ${serviceName} has been set.
    #
    lockFile="${lockDir}/${scriptName}-${serviceName}-${nameSpace}"
    #
    # Check for a ${lockFile} that's similar to ours - same ${serviceName}
    # and ${nameSpace}, but a different PID at the end
    #
    oldLockF=( $(ls -1 ${lockFile}-* 2>/dev/null) )
    if [[ ${#oldLockF[*]} != "0" ]]; then
        # Found one or more of matching files; bailing.
        outError=""
        echo "{\"version\":1, \"code\":400, \"error\":\"Another copy of this script is running: ${oldLockF[@]}\"}"
        exit 0
    else
        # All clear; create a lock file for ourselves
        lockFile+="-$$"
        touch "${lockFile}"
    fi
}

# Talk to K8s API using kubectl to get the info we're after - IPs of the
# nodes where pods are running, and the value of NodePort.
#
getNodes() {
    export KUBECONFIG=${kubeConfig}

    # Get details of our service
    kubectl get svc --namespace="${nameSpace}" "${serviceName}" -o json > ${outFile} 2>${errFile}
    kubeError="$?"
    if [[ "${kubeError}" != "0" ]]; then
        outCode="500"
        outError="kubectl failed to read service '${nameSpace}/${serviceName}': ${kubeError}; does it exist?"
        logMsg "001: 'kubectl get svc' failed: (${kubeError}); $(head -1 ${errFile})"
        printOut
        exit 1
    fi

    # Check if the specified Service is "NodePort"
    svcType=$(cat "${outFile}" | jq -r '.spec.type')
    if [[ "${svcType}" != "NodePort" ]]; then
        outCode="400"
        outError="Specified Service '${nameSpace}/${serviceName}' is not of type 'NodePort'"
        logMsg "002: Got wrong svc type: want 'NodePort', got '${svcType}'"
        printOut
        exit 1
    fi

    # Read the NodePort value
    if [[ "${portName}" != "" ]]; then
        # We were given a Service port name; let's use it
        outPortA=( $(cat "${outFile}" | jq --arg nam "${portName}" -r \
            ".spec.ports[] \
            | select(.name==\$nam) \
            | .nodePort") )
    else
        outPortA=( $(cat "${outFile}" | jq -r '.spec.ports[].nodePort') )
    fi

    # Convert ${outPortA} into string ${outPort}
    IFS=" ", eval 'outPort="${outPortA[*]}"'

    # Test if we have exactly one port in ${outPortA}
    if [[ ${#outPortA[*]} != "1" ]]; then
        outCode="400"
        outError="Didn't get exactly one nodePort: '${outPort}', check Service and/or port name passed to -p"
        logMsg "003: Didn't get exactly one port: '${outPort}'; perhaps wrong name specified with -p"
        printOut
        exit 1
    fi

    # Get the Endpoints for our service to find Service's pods
    kubectl get ep --namespace="${nameSpace}" "${serviceName}" -o json > ${outFile} 2>${errFile}
    kubeError="$?"
    if [[ "${kubeError}" != "0" ]]; then
        outCode="500"
        outError="kubectl failed to get endpoints for '${nameSpace}/${serviceName}': ${kubeError}; see log for details."
        logMsg "004: 'kubectl get ep' failed: (${kubeError}); $(head -1 ${errFile})"
        printOut
        exit 1
    fi

    # After this, we should have a list of pods in ${podList}
    podList=( $(cat "${outFile}" | jq -r '.subsets[].addresses[].targetRef.name') )

    # Get pod details. If we have more than one pod, the answer will be "List"
    if [[ ${#podList[@]} == "0" ]]; then
        # Didn't get any pods..
        outCode="204"
        outError="Got an empty pod list for our endpoint. This shouldn't really be happening."
        printOut
        exit
    fi
    kubectl get pods ${podList[@]} -o json > ${outFile} 2>${errFile}
    kubeError="$?"
    if [[ "${kubeError}" != "0" ]]; then
        outCode="500"
        outError="kubectl failed to get Service's pods: ${kubeError}; see log for details."
        logMsg "005: 'kubectl get pods' failed: (${kubeError}); $(head -1 ${errFile})"
        printOut
        exit 1
    fi

    # Depending on the type of output, we'll use different command to get node IPs
    # If more that one pod is running on the same node, `sort -u` should
    # get rid of duplicates
    #
    answerType=$(cat "${outFile}" | jq -r '.kind')
    case "${answerType}" in
        List) outIPs=( $(cat "${outFile}" | jq -r '.items[].status.hostIP' | sort -u) )
            ;;
        Pod) outIPs=( $(cat "${outFile}" | jq -r '.status.hostIP' | sort -u) )
            ;;
    esac

    # Set the final error code
    if [[ ${#outIPs[@]} != 0 ]]; then
        outCode="200"   # We have the nodes!
    else
        outCode="204"   # No content :)
        outError="Could not find any node IPs."
    fi
}

# Check if we were given a serviceName; we need this to work and to figure
# file name for the lock file
#
if [[ ${serviceName} == "" ]]; then
    echo "{\"version\":1, \"code\":400, \"error\":\"Service Name must be specified with '-s <service name>'\"}"
    exit 1
fi

# Check if we were given a kubeConfFile
#
if [[ ${kubeConfFile} == "" ]]; then
    echo "{\"version\":1, \"code\":400, \"error\":\"Name of kubeconfig file must be given through '-c <kubeconfig file name>'\"}"
    exit 1
fi

checkLock
checkPrerequisites
getNodes
printOut