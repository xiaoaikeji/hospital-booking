import { configurationStatus, hospitalProfile } from '@/store/app-configuration.js'
import { canUseApp } from '@/utils/app-access.js'

export function hospitalLocation({ address_longitude: longitude, address_latitude: latitude }) {
  if (!Number.isFinite(longitude) || Math.abs(longitude) > 180 ||
      !Number.isFinite(latitude) || Math.abs(latitude) > 90 || (latitude === 0 && longitude === 0)) return null
  return { longitude, latitude }
}

export async function openHospitalLocation(visible = () => true) {
  if (!await canUseApp() || !visible()) return
  const hospital = hospitalProfile.value
  const point = configurationStatus.value === 'ready' && hospitalLocation(hospital)
  const unavailable = () => uni.showToast({ title: '来院导航暂不可用，请重试', icon: 'none' })
  if (!point) return unavailable()

  uni.openLocation({
    ...point,
    name: hospital.company_name || '医院',
    address: hospital.address || '',
    scale: 18,
    fail: unavailable,
  })
}
