#!/bin/bash
namespace=${1}
if [[ "X$namespace" == "X" ]];then
   echo "please specify the app registry namespace. For example: openshift-operators-stage, aosqe42"
   exit
fi

#The registry type: quay,stage, brewstage, prod
registry_type=${2:-quay}

#The default operators to be upload
op_images=${3:-elasticsearch-operator cluster-logging-operator ansible-service-broker-operator template-service-broker-operator node-feature-discovery cluster-nfd-operator}

#The version in quay app registry
version="4.1.$(date +%s)"

#The registry DNS
declare -A registry_hash=( ["quay"]="quay.io"
                     ["internal"]="image-registry.openshift-image-registry.svc:5000"
                     ["brew"]="brew-pulp-docker01.web.prod.ext.phx2.redhat.com:8888"
                     ["brewstage"]="brewregistry.stage.redhat.io"
                     ["stage"]="registry.stage.redhat.io"
                     ["prod"]="registry.redhat.io")

# The operator's dir in app registry
declare -A image_registry_dir=( ["elasticsearch-operator"]="elasticsearch-operator" 
	             ["cluster-logging-operator"]="cluster-logging"
	             ["node-feature-discovery"]="node-feature-discovery"
	             ["cluster-nfd-operator"]="cluster-nfd-operator"
	             ["ansible-service-broker-operator"]="openshiftansibleservicebroker"
	             ["template-service-broker-operator"]="openshifttemplateservicebroker")

# The operator image name will be used to update app registry, initial "".
declare -A op_image_hash=( ["elasticsearch-operator"]=""
                     ["cluster-logging-operator"]=""
                     ["node-feature-discovery"]=""
                     ["cluster-nfd-operator"]=""
                     ["ansible-service-broker-operator"]=""
                     ["template-service-broker-operator"]="")



#The image list. The image file be generated by from Advisory
#one image each line For exampe:
#brew-pulp-docker01.web.prod.ext.phx2.redhat.com:8888/openshift/ose-elasticsearch-operator-metadata:v4.1.18-2
if [ -f "ImageList" ] ;then
	num=$(grep -v '#' ImageList | wc -l)
	if [[ $num -eq 0 ]];then
            echo "ImageList is blank"
	    exit 1
	fi
else
    echo "No file ImageList in current directory"
    exit 1
fi

#get the appoint images from ImageList
for op_image in ${op_images}; do

    if [[ "X${image_registry_dir[$op_image]}" == "X" ]]; then
            echo "Warning: ${op_image} is skipped as we couldn't is repo in predefined varaible image_registry_dir, please ping anli append it"
	    continue
    fi

    images=$(grep $op_image ImageList |grep -v '#' )
    if [[ "X${images}" == "X" ]]; then
          echo "Warning: ${op_image} is skipped as we couldn't find the Operator images in ImageList"
	  continue
    fi

    for line in $images; do
	if [[ ${op_image_hash[${op_image}]} == ""  ]] ;then
            # Note: The first found operator image will be used, the following will be ignore except for it is an operator metadata image
            echo "Info: ${op_image} will be updated using $line "
            op_image_hash[${op_image}]=$line
        else
            if [[ ${line} =~ "metadata"  ]] ;then
            # Note: The first found metadata operator image will be used, the following will be ignore
                echo "Info: ${op_image} will be updated using $line "
                op_image_hash[${op_image}]=$line
            fi
	fi
     done
done

function getQuayToken()
{
    if [[ -e ${PWD}/quay.token ]]; then
	    Quay_Token=$(cat ${PWD}/quay.token)
    else 
        echo "##get Quay Token"
        if [[ "X$REG_QUAY_USER" != "X" && "X$REG_QUAY_PASSWORD" != "X" ]]; then
            USERNAME=$REG_QUAY_USER
            PASSWORD=$REG_QUAY_PASSWORD
        else
            USERNAME="anli"
            PASSWORD="aosqe2019"
        fi
        Quay_Token=$(curl -s -H "Content-Type: application/json" -XPOST https://quay.io/cnr/api/v1/users/login -d ' { "user": { "username": "'"${USERNAME}"'", "password": "'"${PASSWORD}"'" } }' |jq -r '.token')
        echo "$Quay_Token" > ${PWD}/quay.token
    fi
}

# copy manifest from images
function getManifest()
{
    echo ""
    echo "#1) Copy manifest from image"
    for key in "${!op_image_hash[@]}"; do
	image=${op_image_hash[$key]}
	if [[ $image == "" ]];then
		continue
	fi
    	brew_image=${image/openshift4/openshift}
    	repo_name="${image_registry_dir[${key}]}"
    	rm -rf $repo_name
	mkdir $repo_name
	echo " extract manifest from $brew_image"
	oc image extract $brew_image --path /manifests/*:$repo_name --insecure=true --confirm
    done
}

function printImageName()
{
    local registry_name=${1}
    echo ""
    echo "#2) print Image Names to ${PWD}/CSV_ImageList"
    for key in "${!op_image_hash[@]}"; do
	image=${op_image_hash[$key]}
	if [[ $image == "" ]];then
		continue
	fi
    	repo_name="${image_registry_dir[${key}]}"
	echo "#The image used in $csv_files"
    	csv_files=$(find $repo_name -name *clusterserviceversion.yaml)
    	if [[ $csv_files != "" ]]; then
                cat $csv_files |grep ${registry_name} |awk '{print $2}' |tr -d '",' |tr -d "'" |sort| uniq | tee -a ${PWD}/CSV_ImageList
                #grep registry.stage.redhat.io  $csv_files |awk '{print $2}' |tr -d '"' |tr -d "'" | tee -a ${PWD}/CSV_ImageList
                #grep registry.redhat.com  $csv_files |awk '{print $2}' |tr -d '"' |tr -d "'" | tee -a ${PWD}/CSV_ImageList
    	fi
    done
}

function pushManifesToRegistry()
{
    echo ""
    echo "#3) push manifest to ${namespace}"
    getQuayToken
    for key in "${!op_image_hash[@]}"; do
	image="${op_image_hash[$key]}"
	if [[ $image == "" ]];then
		continue
	fi
        repo_name="${image_registry_dir[${key}]}"
    	csv_files=$(find $repo_name -name *clusterserviceversion.yaml)
    	if [[ $csv_files != "" ]]; then
                if [[ $registry_type == "quay" ]];then
    		    echo "#Replace image registry to quay"rrr
		    sed -i 's#image-registry.openshift-image-registry.svc:5000/openshift/\(.*\):\(v[^"'\'']*\)#quay.io/openshift-release-dev/ocp-v4.0-art-dev:\2-\1#' $csv_files
                fi

                if [[ $registry_type == "brew" ]];then
                    echo "#Replace image registry to quay"
                    sed -i 's#image-registry.openshift-image-registry.svc:5000#brew-pulp-docker01.web.prod.ext.phx2.redhat.com:8888#' $csv_files
                fi
                if [[ $registry_type == "brewstage" ]];then
                    echo "#Replace image registry to quay"
                    sed -i 's#image-registry.openshift-image-registry.svc:5000#brewregistry.stage.redhat.io#' $csv_files
                fi
                if [[ $registry_type == "prod" ]];then
                    echo "#Replace image registry to quay"
                    sed -i 's#image-registry.openshift-image-registry.svc:5000#registry.redhat.io#' $csv_files
                fi
                if [[ $registry_type == "stage" ]];then
                    echo "#Replace image registry to quay"
                    sed -i 's#image-registry.openshift-image-registry.svc:5000#registry.stage.redhat.io#' $csv_files
                fi

    	fi
        echo "#push manifest ${image_name} to $namespace"
        echo operator-courier --verbose push ${repo_name}/  $namespace ${repo_name} $version  \"$Quay_Token\"
        operator-courier --verbose push ${repo_name}/  ${namespace} ${repo_name} ${version}  "${Quay_Token}"
    done
}

getManifest
pushManifesToRegistry
printImageName  ${registry_hash[$registry_type]}

