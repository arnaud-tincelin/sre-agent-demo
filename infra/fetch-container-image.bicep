// Returns the image a Container App is already running, so re-provisioning does
// not roll the app back to the placeholder image in main.bicep. `azd deploy`
// sets the real image, but `azd provision` on its own would otherwise overwrite it.
param name string
param exists bool

resource existingApp 'Microsoft.App/containerApps@2024-03-01' existing = if (exists) {
  name: name
}

// The `exists` guard already prevents the null dereference; Bicep cannot see that.
#disable-next-line BCP318
output containers array = exists ? existingApp.properties.template.containers : []
