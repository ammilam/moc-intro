#! /bin/bash
################################
##### Author: Andrew Milam #####
################################

######################################
##### Verifies Tool Installation #####
######################################
which jq 2>&1 >/dev/null || (echo "Error, jq executable is required" && exit 1) || exit 1
which terraform 2>&1 >/dev/null || (echo "Error, jq executable is required" && exit 1) || exit 1
which gcloud 2>&1 >/dev/null || (echo "Error, jq executable is required" && exit 1) || exit 1


#####################################
##### Sets GCP Project Variable #####
#####################################
echo ""
export PROJECT="$(gcloud config get-value project)"
echo "Your current configured gcloud project is $PROJECT"
echo ""
echo "Note! This will take some time to deploy and gitlab takes time to completely come up."
echo "Prepare to be wating at least 30 minutes from start to finish."
sleep 2
echo ""

# sets git specific variables
export URL="$(git config --get remote.origin.url)"
export EMAIL="$(git config --get user.email)"


###############################
##### Sets Email Variable #####
###############################
if [[ -z $EMAIL ]]
then
    echo ""
    echo "This implmentation relies on git and requires having global user specific variables set."
    echo "Before executing run the following: "
    echo "
    git config --global user.email \"EMAIL\"
    git config --global user.name \"USERNAME\"
    "
    echo ""
    sleep 2
    exit 0
fi

echo "Your Git user.email global variable is set to : $EMAIL"
echo ""
sleep 2

basename=$(basename $URL)
re="^(https|git)(:\/\/|@)([^\/:]+)[\/:]([^\/:]+)\/(.+).git$"
if [[ $URL =~ $re ]]; then
    USERNAME=${BASH_REMATCH[4]}
    REPO=${BASH_REMATCH[5]}
fi
echo ""
echo "Git is configured for user $USERNAME on the $REPO repository."
echo ""
sleep 2


#######################################################
##### Sets Github Personal Access Token Parameter #####
#######################################################
TOKEN=$(cat token)
if [[ -z $TOKEN ]]
then
    # prompts for github personal access token
    read -p "Enter a github personal access token: " TOKEN
    echo $TOKEN >> token
fi


##################################################################
##### Abstracting Existing Cluster Name From Terraform State #####
##################################################################
if [[ ! -f './terraform.tfstate' ]]
then
    read -p "Enter a cluster name: " NAME
fi
if [[ -f './terraform.tfstate' ]]
then
    export NAME="$(cat terraform.tfstate|jq -r '.outputs.cluster_name.value')"
    echo "Your existing cluster is called $NAME"
    echo ""
    sleep 2
fi

##################################################
##### Service Account Creation For Terraform #####
##################################################
SA_NAME=terraform-deploy
gcloud iam service-accounts create $SA_NAME
GCP_USER=$(gcloud config get-value account)
gcloud projects add-iam-policy-binding $PROJECT --member="user:${GCP_USER}" --role="roles/iam.serviceAccountUser"
gcloud projects add-iam-policy-binding $PROJECT --member="serviceAccount:${SA_NAME}@${PROJECT}.iam.gserviceaccount.com" --role="roles/owner"
#gcloud auth activate-service-account "${SA_NAME}@${PROJECT}.iam.gserviceaccount.com" --key-file=./$GOOGLE_APPLICATION_CREDENTIALS
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export GOOGLE_APPLICATION_CREDENTIALS="${SA_NAME}-${PROJECT}.json"


##########################################
##### Terraform Apply With Variables #####
##########################################
echo ""
terraform fmt --recursive
terraform init
sleep 5
terraform apply -var "google_credentials=${GOOGLE_APPLICATION_CREDENTIALS}" -var "repo=${REPO}" -var "github_token=${TOKEN}" -var "username=${USERNAME}" -var "email_address=${EMAIL}" -var "cluster_name=${NAME}" -var "project_id=${PROJECT}" -auto-approve
sleep 5


##################################################
##### Sets Kubernetes Context To GKE CLuster #####
##################################################
export REGION=$(cat terraform.tfstate|jq -r '.outputs.location.value')
echo "Getting kubeconfig for the GKE cluster..."
echo ""
sleep 2
gcloud container clusters get-credentials $NAME --zone $REGION --project $PROJECT -q
echo ""

if [[ -z $(kubectl get secrets -o json|jq -r '.items[].metadata.name'|grep my-secret) ]]
then
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout tls.key -out tls.crt -subj "/CN=fake.gitlab.com"
    kubectl create secret tls my-secret --key="tls.key" --cert="tls.crt"
    rm tls.*
fi

######################################
##### Sets User As Cluster Admin #####
######################################
if [[ -z $(kubectl get clusterrolebinding cluster-admin-binding) ]]
then
    echo "Setting current user as cluster admin"
    echo ""
    sleep 2
    kubectl create clusterrolebinding cluster-admin-binding \
    --clusterrole cluster-admin \
    --user $(gcloud config get-value account)
    echo ""
fi