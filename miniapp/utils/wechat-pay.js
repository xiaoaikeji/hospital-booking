// queryPayment reads the business order from Booking, including after a cancelled cashier.
export async function requestWechatPayment(paymentNo, params, queryPayment) {
  const { timeStamp, nonceStr, package: prepay, signType, paySign } = params
  const cashier = await new Promise((resolve) => {
    uni.requestPayment({
      provider: 'wxpay', timeStamp, nonceStr, package: prepay, signType, paySign,
      success: () => resolve('returned'),
      fail: (error) => resolve(/\bcancel(?:led)?\b/i.test(error?.errMsg || '') ? 'cancelled' : 'failed'),
    })
  }).catch(() => 'failed')
  const payment = await queryPayment(paymentNo)
  return { cashier, payment }
}
