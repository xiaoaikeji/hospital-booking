import assert from 'node:assert/strict'
import { test } from 'node:test'
import { requestWechatPayment } from '../utils/wechat-pay.js'

const paymentNo = '20261123090000123456'
const params = { timeStamp: '1700000000', nonceStr: 'example', package: 'prepay_id=example', signType: 'RSA', paySign: 'test' }

test('all cashier outcomes query the same business order and use only its server status', async () => {
  for (const [cashier, signType] of [['returned', 'RSA'], ['cancelled', 'HMAC-SHA256'], ['failed', 'RSA']]) {
    const signed = { ...params, signType }
    globalThis.uni = { requestPayment({ success, fail, ...fields }) {
      assert.deepEqual(fields, { ...signed, provider: 'wxpay' })
      if (cashier === 'returned') success()
      else fail({ errMsg: cashier === 'cancelled' ? 'requestPayment:fail cancel' : 'requestPayment:fail network' })
    } }
    const lookups = []
    const result = await requestWechatPayment(paymentNo, signed, async (number) => {
      lookups.push(number)
      return { state: 'NOTPAY' }
    })
    assert.deepEqual(lookups, [paymentNo])
    assert.deepEqual(result, { cashier, payment: { state: 'NOTPAY' } })
  }
})

test('loss of connectivity after returning from WeChat leaves confirmation outstanding', async () => {
  globalThis.uni = { requestPayment({ success }) { success() } }
  await assert.rejects(requestWechatPayment(paymentNo, params, async () => { throw new Error('offline') }), /offline/)
})
