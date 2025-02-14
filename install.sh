#!/usr/bin/env bash

export ns="knoxagents"
while getopts ":n:" opt; do
  case $opt in
    n)
	  ns=$OPTARG
      ;;
    \?)
      echo "Invalid option: -$OPTARG" >&2
      exit 1
      ;;
    :)
      echo "Specify namespace" >&2
      exit 1
      ;;
  esac
done

if [ -f "common.sh" ]; then
	. common.sh
else
	source <(curl -s https://raw.githubusercontent.com/accuknox/tools/main/common.sh)
fi

install_karmor_help()
{
	echo "karmor cli tool not found. Use following to install:"
	echo -en "\tcurl -sfL https://raw.githubusercontent.com/kubearmor/kubearmor-client/main/install.sh | sudo sh -s -- -b /usr/local/bin\n"
	echo -en "\tRef: https://github.com/kubearmor/kubearmor-client\n"
}

install_cilium_help()
{
	echo "cilium cli tool not found. Use following to install:"
	cat << END
	curl -L --remote-name-all https://github.com/cilium/cilium-cli/releases/latest/download/cilium-linux-amd64.tar.gz{,.sha256sum}
	sha256sum --check cilium-linux-amd64.tar.gz.sha256sum
	sudo tar xzvfC cilium-linux-amd64.tar.gz /usr/local/bin
	rm cilium-linux-amd64.tar.gz{,.sha256sum}

	Ref: https://docs.cilium.io/en/stable/gettingstarted/k8s-install-default/#install-the-cilium-cli
END
}

check_prerequisites()
{
	command -v curl >/dev/null 2>&1 || 
		{ 
			statusline NOK "curl tool not found"
			exit 1
		}
	command -v helm >/dev/null 2>&1 || 
		{ 
			echo "Use this command to install helm:"
			echo "		curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash"
			statusline NOK "helm tool not found"
			exit 1
		}
	statusline AOK "helm found"
	command -v karmor >/dev/null 2>&1 ||
		{
			install_karmor_help
			statusline NOK "karmor tool not found"
			exit 1
		}
	statusline AOK "karmor cli tool found"
	command -v cilium >/dev/null 2>&1 ||
		{
			install_cilium_help
			echo "Require 'cilium' cli tool."
			statusline NOK "cilium cli tool not found"
			exit 1
		}
	statusline AOK "cilium cli tool found"
	kubectl config current-context view 2>/dev/null
	statusline $? "k8s cluster accessibility"
}

installMysql() {
	kubectl get pod -n $ns -l "app.kubernetes.io/name=mysql" | grep "mysql" >/dev/null 2>&1
	[[ $? -eq 0 ]] && statusline AOK "mysql already installed" && return 0
    statusline WAIT "installing mysql"
    helm install --wait mysql bitnami/mysql --version 8.6.1 \
		--namespace $ns \
		--set auth.user="test-user" \
		--set auth.password="password" \
		--set auth.rootPassword="password" \
		--set auth.database="knoxautopolicy"
	statusline AOK "mysql installed"
}

installFeeder(){
    HELM_FEEDER="helm install feeder-service-cilium feeder --namespace=$ns --set image.repository=\"accuknox/test-feeder\" --set image.tag=\"latest\" "
    case $PLATFORM in
        gke)
            HELM_FEEDER="${HELM_FEEDER} --set platform=gke"
        ;;
        self-managed)
        ;;
        *)
            HELM_FEEDER="${HELM_FEEDER} --set kubearmor.enabled=false"
    esac
    eval "$HELM_FEEDER"
}

installCilium() {
    # FIXME this assumes that the project id, zone, and cluster name can't have
    # any underscores b/w them which might be a wrong assumption
	# PROJECT_ID="$(echo "$CURRENT_CONTEXT_NAME" | awk -F '_' '{print $2}')"
	# ZONE="$(echo "$CURRENT_CONTEXT_NAME" | awk -F '_' '{print $3}')"
	# CLUSTER_NAME="$(echo "$CURRENT_CONTEXT_NAME" | awk -F '_' '{print $4}')"
	kubectl get pod -A -l k8s-app=cilium | grep "cilium" >/dev/null 2>&1
	[[ $? -eq 0 ]] && statusline AOK "cilium already installed" && return 0
    statusline WAIT "Installing Cilium on $PLATFORM Kubernetes Cluster"
    cilium install -n $ns
	cilium -n $ns hubble enable
	cilium status -n $ns --wait --wait-duration 5m
	statusline $? "cilium installation"
: << 'END'
    case $PLATFORM in
        gke)
        	NATIVE_CIDR="$(gcloud container clusters describe "$CLUSTER_NAME" --zone "$ZONE" --project "$PROJECT_ID" --format 'value(clusterIpv4Cidr)')"
            helm install cilium cilium \
            --set image.repository=docker.io/accuknox/cilium-ci \
            --set image.tag=3228007c8b07ad626cb16c80476e4846b4eb008e \
            --set operator.image.repository=docker.io/accuknox/operator \
            --set operator.image.suffix=-ci \
            --set operator.image.tag=identity-solution \
            --set operator.image.useDigest=false \
			--namespace $ns \
            --set nodeinit.enabled=true \
           --set nodeinit.reconfigureKubelet=true \
            --set nodeinit.removeCbrBridge=true \
            --set cni.binPath=/home/kubernetes/bin \
            --set gke.enabled=true \
            --set ipam.mode=kubernetes  \
            --set hubble.relay.enabled=true \
            --set hubble.ui.enabled=true \
            --set nativeRoutingCIDR="$NATIVE_CIDR"\
            --set prometheus.enabled=true\
            --set operator.prometheus.enabled=true
        ;;

        *)
            helm install cilium cilium \
			--namespace $ns \
            --set image.repository=docker.io/accuknox/cilium-ci \
            --set image.tag=3228007c8b07ad626cb16c80476e4846b4eb008e \
            --set operator.image.repository=docker.io/accuknox/operator \
            --set operator.image.suffix=-ci \
            --set operator.image.tag=identity-solution \
            --set operator.image.useDigest=false \
            --set hubble.relay.enabled=true \
            --set prometheus.enabled=true \
            --set cgroup.autoMount.enabled=false \
            --set operator.prometheus.enabled=true
        ;;
    esac
END
	# Installing cilium using cilium operator
}

installSpire(){
    helm install spire spire --namespace=$ns
}

function show_license() {
	cat << EOF
---=[License]=---
1. KubeArmor is licensed under the Apache License, Version 2.0. For details check (https://github.com/kubearmor/KubeArmor/blob/main/LICENSE)
2. The Cilium user space components are licensed under the Apache License, Version 2.0. The BPF code templates are licensed under the General Public License, Version 2.0.

EOF
    statusline AOK "Please read the license"
	sleep 1
}

show_license
check_prerequisites
helm repo add bitnami https://charts.bitnami.com/bitnami &> /dev/null
helm repo update

kubectl get ns $ns >/dev/null 2>&1
[[ $? -ne 0 ]] && kubectl create ns $ns
statusline AOK "$ns namespace created/already present."

autoDetectEnvironment

installCilium
handleLocalStorage apply
installMysql
#installFeeder
#handlePrometheusAndGrafana apply

handleKubearmor apply
# handleKubearmorPrometheusClient apply

handleKnoxAutoPolicy apply
#installSpire
 
