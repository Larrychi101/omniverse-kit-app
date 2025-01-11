@description('The location used for all deployed resources')
param location string = resourceGroup().location

@description('Tags that will be applied to all resources')
param tags object = {}


param kitAppstreamingResourcesV180Exists bool
@secure()
param kitAppstreamingResourcesV180Definition object

@description('Id of the user or app to assign application roles')
param principalId string

var abbrs = loadJsonContent('./abbreviations.json')
var resourceToken = uniqueString(subscription().id, resourceGroup().id, location)

// Monitor application with Azure Monitor
module monitoring 'br/public:avm/ptn/azd/monitoring:0.1.0' = {
  name: 'monitoring'
  params: {
    logAnalyticsName: '${abbrs.operationalInsightsWorkspaces}${resourceToken}'
    applicationInsightsName: '${abbrs.insightsComponents}${resourceToken}'
    applicationInsightsDashboardName: '${abbrs.portalDashboards}${resourceToken}'
    location: location
    tags: tags
  }
}

// Container registry
module containerRegistry 'br/public:avm/res/container-registry/registry:0.1.1' = {
  name: 'registry'
  params: {
    name: '${abbrs.containerRegistryRegistries}${resourceToken}'
    location: location
    acrAdminUserEnabled: true
    tags: tags
    publicNetworkAccess: 'Enabled'
    roleAssignments:[
      {
        principalId: kitAppstreamingResourcesV180Identity.outputs.principalId
        principalType: 'ServicePrincipal'
        roleDefinitionIdOrName: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')
      }
    ]
  }
}

// Container apps environment
module containerAppsEnvironment 'br/public:avm/res/app/managed-environment:0.4.5' = {
  name: 'container-apps-environment'
  params: {
    logAnalyticsWorkspaceResourceId: monitoring.outputs.logAnalyticsWorkspaceResourceId
    name: '${abbrs.appManagedEnvironments}${resourceToken}'
    location: location
    zoneRedundant: false
  }
}

module kitAppstreamingResourcesV180Identity 'br/public:avm/res/managed-identity/user-assigned-identity:0.2.1' = {
  name: 'kitAppstreamingResourcesV180identity'
  params: {
    name: '${abbrs.managedIdentityUserAssignedIdentities}kitAppstreamingResourcesV180-${resourceToken}'
    location: location
  }
}

module kitAppstreamingResourcesV180FetchLatestImage './modules/fetch-container-image.bicep' = {
  name: 'kitAppstreamingResourcesV180-fetch-image'
  params: {
    exists: kitAppstreamingResourcesV180Exists
    name: 'kit-appstreaming-resources-v1-8-0'
  }
}

var kitAppstreamingResourcesV180AppSettingsArray = filter(array(kitAppstreamingResourcesV180Definition.settings), i => i.name != '')
var kitAppstreamingResourcesV180Secrets = map(filter(kitAppstreamingResourcesV180AppSettingsArray, i => i.?secret != null), i => {
  name: i.name
  value: i.value
  secretRef: i.?secretRef ?? take(replace(replace(toLower(i.name), '_', '-'), '.', '-'), 32)
})
var kitAppstreamingResourcesV180Env = map(filter(kitAppstreamingResourcesV180AppSettingsArray, i => i.?secret == null), i => {
  name: i.name
  value: i.value
})

module kitAppstreamingResourcesV180 'br/public:avm/res/app/container-app:0.8.0' = {
  name: 'kitAppstreamingResourcesV180'
  params: {
    name: 'kit-appstreaming-resources-v1-8-0'
    ingressTargetPort: 80
    scaleMinReplicas: 1
    scaleMaxReplicas: 10
    secrets: {
      secureList:  union([
      ],
      map(kitAppstreamingResourcesV180Secrets, secret => {
        name: secret.secretRef
        value: secret.value
      }))
    }
    containers: [
      {
        image: kitAppstreamingResourcesV180FetchLatestImage.outputs.?containers[?0].?image ?? 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'
        name: 'main'
        resources: {
          cpu: json('0.5')
          memory: '1.0Gi'
        }
        env: union([
          {
            name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
            value: monitoring.outputs.applicationInsightsConnectionString
          }
          {
            name: 'AZURE_CLIENT_ID'
            value: kitAppstreamingResourcesV180Identity.outputs.clientId
          }
          {
            name: 'PORT'
            value: '80'
          }
        ],
        kitAppstreamingResourcesV180Env,
        map(kitAppstreamingResourcesV180Secrets, secret => {
            name: secret.name
            secretRef: secret.secretRef
        }))
      }
    ]
    managedIdentities:{
      systemAssigned: false
      userAssignedResourceIds: [kitAppstreamingResourcesV180Identity.outputs.resourceId]
    }
    registries:[
      {
        server: containerRegistry.outputs.loginServer
        identity: kitAppstreamingResourcesV180Identity.outputs.resourceId
      }
    ]
    environmentResourceId: containerAppsEnvironment.outputs.resourceId
    location: location
    tags: union(tags, { 'azd-service-name': 'kit-appstreaming-resources-v1-8-0' })
  }
}
// Create a keyvault to store secrets
module keyVault 'br/public:avm/res/key-vault/vault:0.6.1' = {
  name: 'keyvault'
  params: {
    name: '${abbrs.keyVaultVaults}${resourceToken}'
    location: location
    tags: tags
    enableRbacAuthorization: false
    accessPolicies: [
      {
        objectId: principalId
        permissions: {
          secrets: [ 'get', 'list' ]
        }
      }
      {
        objectId: kitAppstreamingResourcesV180Identity.outputs.principalId
        permissions: {
          secrets: [ 'get', 'list' ]
        }
      }
    ]
    secrets: [
    ]
  }
}
output AZURE_CONTAINER_REGISTRY_ENDPOINT string = containerRegistry.outputs.loginServer
output AZURE_KEY_VAULT_ENDPOINT string = keyVault.outputs.uri
output AZURE_KEY_VAULT_NAME string = keyVault.outputs.name
output AZURE_RESOURCE_KIT_APPSTREAMING_RESOURCES_V1_8_0_ID string = kitAppstreamingResourcesV180.outputs.resourceId
