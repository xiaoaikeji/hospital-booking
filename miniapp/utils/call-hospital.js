export function callHospital(phone) {
  const phoneNumber = phone.replace(/[\s()（）-]/g, '')
  uni.makePhoneCall({
    phoneNumber,
    fail({ errMsg }) {
      if (!errMsg?.includes('cancel')) {
        uni.showToast({ title: '暂时无法拨打，请核对号码', icon: 'none' })
      }
    },
  })
}
