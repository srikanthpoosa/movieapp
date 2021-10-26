

## This script creates the AKS Cluster 
## Integrate with Azure AD if provided, Use Windows Feature if provided
## Also creates the NGINX Ingress Controller, assigning the Cluster Role binding for the AKS dashboard etc.
## Try to make all params mandatory, so that we can make sure its created not with default values mostly.
Param
  (
    [Parameter(Mandatory=$true)][string]$ResourceGroupName,
    [Parameter(Mandatory=$true)][string]$ResourceGroupLocation,
    [Parameter(Mandatory=$true)][string]$ACRName,
    [Parameter(Mandatory=$true)][string]$ACRResourceGroupName,
    [Parameter(Mandatory=$true)][string]$ACRSubscriptionName,
    [Parameter(Mandatory=$true)][string]$SubscriptionName,
    [Parameter(Mandatory=$true)][string]$ClusterName,
    [parameter(Mandatory=$true)][int]$NodeCount,
    [parameter(Mandatory=$true)][int]$NodeGBSize,
    [parameter(Mandatory=$true)][string]$NodeSize,  
    [parameter(Mandatory=$true)][string]$NodePoolName, ## Only 12 char - alphanumeric with small case for linux and only 6 char for Windows node type
    [parameter(Mandatory=$true)][int]$MinCount,
    [parameter(Mandatory=$true)][int]$MaxCount,
    [parameter(Mandatory=$true)][string]$Environment,
    [parameter(Mandatory=$true)][string]$TagName,    
    [Parameter(Mandatory=$true)][string]$DNSName,
    [Parameter()][string]$Namespace = "default",
    [parameter()][string]$Zones1, ##Setting the zones e.g. 1 2 3 for deploying the node/pod across multi-zones in a region for high availability
    [parameter()][string]$Zones2,
    [parameter()][string]$Zones3,
    #[parameter(Mandatory)][string]$HelmRBACPath, ## This is for Helm RBAC
    [parameter()][string]$GrafanaValuesYamlPath = "values.yaml", ## This is for Grafana Values Yaml path, for Grafana & Prometheus Installation
    [parameter()][string]$KubeDashboardYamlPath = "rbac_readonly_dashboard.yaml", ## This is for Kube Dashboard ClusterRole Yaml path, we're doing it as a readonly dashboard
    [parameter()][string]$OctopusServiceAccountYamlPath = "octopus_serviceaccount.yaml", ## This is for Octopus to deploy the apps into AKS Cluster which is AD integrated. This uses Service Account instead of Service Principals
    [parameter()][string]$IngressControllerConfigYamlPath = "ingress-controller-config.yaml", ## This is for NGINX Ingress Controller Config
    [parameter()][string]$WindowsPassword, ## This is for Windows Container support   
    [parameter()][bool]$UseExistingSSH = $false,
    [Parameter()][string]$DNSNamePrefix,
    [parameter()][int]$MaxPods = 40,
    [parameter()][string]$KubenetesVersion = "1.16.13",
    [parameter()][string]$AdminUser = "azureuser",
    [parameter()][string]$VNetName,
    [parameter()][string]$VNetResourceGroupName,
    [parameter()][string]$SubnetName,
    [parameter()][string]$ServerApplicationId,
    [parameter()][string]$ServerApplicationSecret,
    [parameter()][string]$ClientApplicationId,
    [parameter()][string]$TenantId,
    [parameter()][string]$SPId, ##Provide exising Service Principal Id
    [parameter()][string]$SPPwd, ##Provide exising Service Principal Password
    [parameter()][string]$AdminGroupYamlPath = "rbac_admin_group.yaml",
    [parameter()][string]$ReadOnlyGroupYamlPath = "rbac_readonly_group.yaml"
    #endregion
  )

  # Create Resource Group for AKS Cluster if not present
  if ((az group exists --name $ResourceGroupName --subscription $SubscriptionName) -eq $true)
  {
    Write-Host "ResourceGroupName already exists : `"$ResourceGroupName`""
  }
  else
  {
    Write-Host "Creating ResourceGroupName : `"$ResourceGroupName`""
    az group create --location $ResourceGroupLocation --name $ResourceGroupName --subscription $SubscriptionName
  }

  # Assign the DNSNamePrefix if not provided based on ClusterName
  If ($DNSNamePrefix.Trim() -eq '') 
  {
    $DNSNamePrefix = $ClusterName
    Write-Host "DNSNamePrefix    : `"$DNSNamePrefix`""
  }
  
  # Root Path of the Directory
  $RootPath = (Get-Item -Path ".\").FullName
  Write-Host $RootPath

  try
  {
    # AD Service Principal
    Write-Host "Service Principal"
    $spPwd=$SPPwd
    Write-Host "spPwd    : `"$spPwd`""

    # Get the SP appId
    $appId=$SPId
    Write-Host "appId    : `"$appId`""

    #Deploy into Multi Availability Zones or not based on passed values. If require zonal based then need to pass the values accordingly in Zones1, Zones2 and Zones 3 param.
    ##Note: Key in zones values by order Zones1/Zones2/Zones3 (e.g. if you need to deploy into two zones, pass the values in Zones1 and Zones2 param only)
    If ($Zones1 -ne $null -and $Zones1.Trim() -ne '') 
    {    
        $AZones = "--zones", $Zones1+$Zones2+$Zones3
        $AZones = $AZones.Trim()
        Write-Host "Deploying into multi Availability Zones : `"$Zones`""
        Write-Host $AZones
    }
    else
    {
        Write-Host "Deploying without Availability Zones"
        $AZones = ''
    }

    If ($VNetName -ne $null -and $SubnetName -ne $null -and $VNetName.Trim() -ne '' -and $SubnetName.Trim() -ne '') 
    {
        # Assign VNET/ Subnet
        $VNET_ID=$(az network vnet show --resource-group $VNetResourceGroupName --name $VNetName --subscription $SubscriptionName --query id -o tsv)
        Write-Host "VNET_ID    : `"$VNET_ID`""

        # Get the subnet
        $SubnetId=$(az network vnet subnet show --resource-group $VNetResourceGroupName --vnet-name $VNetName --name $SubnetName --subscription $SubscriptionName --query id --output tsv)
        Write-Host "SubnetId    : `"$SubnetId`""
    }

    ## These are conditions params to be included or not while creating the AKS Cluster based on the provided parameters
    # Integration with Azure AD or not
    If ($ServerApplicationId -ne $null -and $ClientApplicationId -ne $null -and $ServerApplicationId.Trim() -ne '' -and $ClientApplicationId.Trim() -ne '') 
    {
        Write-Host "Deploying with AAD integration"
        $AAD = "--aad-server-app-id", $ServerApplicationId, "--aad-server-app-secret", $ServerApplicationSecret, "--aad-client-app-id", $ClientApplicationId, "--aad-tenant-id", $TenantId
        Write-Host $AAD
    }
    else
    {
        Write-Host "Deploying without AAD integration"
        $AAD = ''
    }

    # Deploy into existing VNET or not
    if ($SubnetId -ne $null -and $SubnetId.Trim() -ne '')
    {
        Write-Host "Deploying into existing Subnet : `"$SubnetId`""
        $Subnet = "--vnet-subnet-id", $SubnetId
        Write-Host $Subnet
    }
    else
    {
        Write-Host "Deploying into new SubnetId"
        $Subnet = ''
    }

    # Enable Windows Container Feature or not
    if ($WindowsPassword -ne $null -and $WindowsPassword.Trim() -ne '')
    {
        Write-Host "Deploying with Windows Container Feature"
        $WindowsContainerFeature = "--windows-admin-password", $WindowsPassword, "--windows-admin-username", $AdminUser
        Write-Host $WindowsContainerFeature
    }
    else
    {
        Write-Host "Deploying without Windows Container Feature"
        $WindowsContainerFeature = ''
    }

    # Use existing SSH or generate new
    if ($UseExistingSSH -ne $null -and $UseExistingSSH -eq $true)
    {
        Write-Host "Deploying with existing SSH Keys"
        $SSHPath = Join-Path $RootPath '\.ssh\id_rsa.pub'
        $SSH = "--ssh-key-value", $SSHPath
        Write-Host $SSH
    }
    else
    {
        Write-Host "Deploy by generating new SSH Keys"
        $SSH = "--generate-ssh-keys"
    }

    # Create AKS Cluster
    Write-Host "Creating the AKS Cluster"
    az aks create --name $ClusterName --resource-group $ResourceGroupName --location $ResourceGroupLocation --subscription $SubscriptionName `
    --node-count $NodeCount --max-pods $MaxPods --node-osdisk-size $NodeGBSize --dns-name-prefix $DNSNamePrefix --kubernetes-version $KubenetesVersion `
    --service-principal $appId --client-secret $spPwd --node-vm-size $NodeSize --network-plugin azure --nodepool-name $NodePoolName --admin-username $AdminUser `
    --enable-cluster-autoscaler --vm-set-type VirtualMachineScaleSets --min-count $MinCount --max-count $Maxcount `
    --tags resourceName=AzureKubernetesService projectName=SMART documentTeam=Common environment=$Environment name=$TagName resourceType=AKS $Subnet $SSH $AAD $WindowsContainerFeature `
    $AZones --verbose
    
    # Get the AKS context & merge to it 
    Write-Host "Merging the credentials to the Cluster"
    az aks get-credentials --resource-group $ResourceGroupName --name $ClusterName --subscription $SubscriptionName --admin --overwrite-existing
    if ($LastExitCode)
    {
        Write-Host "Error Occurred either while creating AKS Cluster or merging the Context of the AKS Cluster" -fore Red
        throw 'Error Occurred either while creating AKS Cluster or merging the Context of the AKS Cluster'
    }

    #kubectl config set-context --name $ClusterName

    #region Ingress Controller via Helm
    # Before executing the NGINX, you need to have the Helm installed in the client machine where you're running the helm command
    # You can install helm via Choco, first install choco if you don't have that
    
    Write-Host "Install Choco & Helm"
    Set-ExecutionPolicy Bypass -Scope Process -Force; iex ((New-Object System.Net.WebClient).DownloadString('https://chocolatey.org/install.ps1'))

    ##Install Helm
    choco install kubernetes-helm --force -y

    # Install the Certs as secret and be consumed by the Ingress
    # TODO: Look out to get the certs key/cert via keyvault through this PS
    $CertKeyPath = Join-Path $RootPath '\Certs\gep.key'
    $CertPath = Join-Path $RootPath '\Certs\gep.crt'
    kubectl create secret tls aks-gep-latest-ingress-tls --namespace default --key $CertKeyPath --cert $CertPath --save-config --dry-run=client -o yaml | kubectl apply -f -

    # Install NGINX controller
    Write-Host "NGINX Install"

    helm repo add stable https://charts.helm.sh/stable
    helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
    helm repo update

    helm install ingress-nginx ingress-nginx/ingress-nginx --set controller.replicaCount=3 --set controller.nodeSelector."beta\.kubernetes\.io/os"=linux --set defaultBackend.nodeSelector."beta\.kubernetes\.io/os"=linux --set controller.publishService.enabled=true --set controller.service.annotations."service\.beta\.kubernetes\.io/azure-dns-label-name"=$DNSName --namespace $Namespace

    Write-Host "Create NGINX Ingress Controller Config"
    $IngressConfigYamlPath =  Join-Path $RootPath $IngressControllerConfigYamlPath
    kubectl apply -f $IngressConfigYamlPath
    #endregion

    # AKS Readonly Dashboard as Cluster Role Binding to the AKS Cluster
    Write-Host "Assigning Readonly Dashboard as Cluster Role Binding to the AKS Cluster"
    $ReadOnlyKubeDashboardYamlPath =  Join-Path $RootPath $KubeDashboardYamlPath
    kubectl apply -f $ReadOnlyKubeDashboardYamlPath
    Start-Sleep -s 30 # Sleep for 30 sec, before assigning to the kubernetes-dashboard   
    #kubectl create clusterrolebinding kubernetes-dashboard --clusterrole=cluster-admin --serviceaccount=kube-system:kubernetes-dashboard --dry-run=client --save-config -o yaml | kubectl apply -f -
    kubectl create clusterrolebinding kubernetes-dashboard --clusterrole=readonly-dashboard --serviceaccount=kube-system:kubernetes-dashboard --dry-run=client --save-config -o yaml | kubectl apply -f -

    # AKS ClusterAdmin assignment to the Service Account for Octopus deployments
    Write-Host "AKS ClusterAdmin assignment to the Service Account for Octopus deployments"
    kubectl apply -f $OctopusServiceAccountYamlPath

    # Execute the AZ Admin & Read Only Group - Cluster Role Binding
    $AdminADGroupYamlPath =  Join-Path $RootPath $AdminGroupYamlPath
    $ReadOnlyADGroupYamlPath =  Join-Path $RootPath $ReadOnlyGroupYamlPath
    kubectl apply -f $AdminADGroupYamlPath
    kubectl apply -f $ReadOnlyADGroupYamlPath
    
    #region Grafana & Prometheus for Cluster Monitoring and Dashboard
    kubectl create namespace monitoring 
    helm install prometheus stable/prometheus --namespace monitoring
    helm install grafana stable/grafana --namespace monitoring

    $GrafanaHelmValuesPath = Join-Path $RootPath $GrafanaValuesYamlPath
    helm upgrade -f $GrafanaHelmValuesPath grafana stable/grafana --namespace monitoring       ## Make sure in graffana-values.yaml, the dashboard json template path is updated correctly 

    # This is to port-forward and login to the Grafana dashboard, execute below cmd manually whenever you want to login to the Grafana dashboard
    #$POD_NAME=$(kubectl get pods --namespace monitoring -l "app=grafana,release=grafana" -o jsonpath="{.items[0].metadata.name}")
    #kubectl --namespace monitoring port-forward $POD_NAME 3000
    #endregion
}
catch
{
    Write-Host ($_)
    throw $_
    exit
}
kubernetes cluster creation.txt
Displaying kubernetes cluster creation.txt.
