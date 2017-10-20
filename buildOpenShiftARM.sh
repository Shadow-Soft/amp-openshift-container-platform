#/bin/sh

if [[ $1 == "" ]]
then
   echo "Please provide a new resource group name as a first parameter"
   exit 1
fi

az account show
if [ $? -eq 1 ]
then
	az login
fi

$RESGROUP=$1

az group create -l eastus -n $RESGROUP

az group deployment create --name ocpdeployment --template-urihttps://raw.githubusercontent.com/Shadow-Soft/amp-openshift-container-platform/master/mainTemplate.json--parameters @mainTemplate.parameters.json --resource-group $RESGROUP --no-wait
