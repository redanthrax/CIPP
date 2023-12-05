import { CippWizard } from 'src/components/layout'
import { Field } from 'react-final-form'
import { WizardTableField } from 'src/components/tables'

const AddLob = () => {
  return (
    <CippWizard wizardTitle="Add LOB App">
      <CippWizard.Page
        title="Tenant Choice"
        description="Choose the tenants to apply the application."
      >
        <center>
          <h3 className="text-primary">Step 1</h3>
          <h5 className="card-title mb-4">Choose a tenant</h5>
        </center>
        <hr className="my-4" />
        <Field name="selectedTenants">
          {(props) => (
            <WizardTableField
              reportName="Add-Choco-App-Tenant-Selector"
              keyField="defaultDomainName"
              path="/api/ListTenants?AllTenantSelector=true"
              columns={[
                {
                  name: 'Display Name',
                  selector: (row) => row['displayName'],
                  sortable: true,
                  exportselector: 'displayName',
                },
                {
                  name: 'Default Domain Name',
                  selector: (row) => row['defaultDomainName'],
                  sortable: true,
                  exportselector: 'mail',
                },
              ]}
              fieldProps={props}
            />
          )}
        </Field>
        <hr className="my-4" />
      </CippWizard.Page>
    </CippWizard>
  )
}

export default AddLob
