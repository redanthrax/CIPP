import { useQuery } from '@tanstack/react-query'
import { useSettings } from './use-settings'
import {
  findTenantCloud,
  getGovernmentClouds,
} from '../utils/cloud-feature-support'

// Reads the tenant list the tenant selector already loaded (query key TenantSelector) without
// fetching it again: `enabled: false` only subscribes to the cache. Until the list is in the
// cache the cloud is unknown and nothing is gated (redanthrax/CIPP#4).
const useTenantList = () =>
  useQuery({ queryKey: ['TenantSelector'], enabled: false }).data

// The selected tenant's cloud (Commercial, USGovHigh, USGovDoD), or undefined for AllTenants,
// an unknown tenant or before the tenant list has loaded.
export const useTenantCloudEnvironment = (tenant) => {
  const settings = useSettings()
  const tenants = useTenantList()
  return findTenantCloud(tenants, tenant ?? settings?.currentTenant)
}

// The government clouds among the tenants the user can see ([] for a commercial-only estate).
export const useGovernmentClouds = () => getGovernmentClouds(useTenantList())
