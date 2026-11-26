import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { test } from 'node:test'
import { Script } from 'node:vm'

const date = '2026-11-30'
const doctorId = '42'
const night = remaining => ({ time_slot: 'NIGHT', label: '晚班', total: 4, remaining })
const days = (...shifts) => [{ date, availability: { [doctorId]: shifts } }]
const ref = value => ({ value })
const computed = read => ({ get value() { return read() } })
const source = readFileSync(new URL('../pages/booking/form.vue', import.meta.url), 'utf8')
const setup = source.match(/<script setup>\s*([\s\S]*?)<\/script>/)[1].replace(/^import .*\n/gm, '')
// Run the page's handlers with the uni-app hooks and calendar store provided by the fixture.
const bookingForm = new Script(`${setup}\n({ selectTime, setTime, confirmBooking, picking, doctor, date, selectedSlot, name, sex, age, phone, symptoms })`)

async function openForm() {
  const schedule = ref(days(night(4)))
  const selectedDate = ref('')
  const selectedDay = computed(() => schedule.value.find(day => day.date === selectedDate.value) || schedule.value[0])
  const bookingSymptomsRequired = ref(false)
  const messages = []
  let mount
  let response
  let requests = 0
  const checkAppAccess = async () => {
    requests++
    schedule.value = await response
  }
  const canUseApp = async () => {
    await checkAppAccess()
    return true
  }
  const form = bookingForm.runInNewContext({
    ref, computed,
    watch() {},
    onLoad(handler) { mount = handler },
    onShow() {},
    directoryDemoMode: false,
    demoMode: false,
    findBookingDoctor: id => ({ id }),
    useBookingCalendar: () => ({ schedule, selectedDate, selectedDay, refresh() {} }),
    bookingShifts: (day, id) => day?.availability?.[id] ?? [],
    signedIn: ref(true),
    loadPatients: async () => [],
    readProfile: async () => ({ booking_phone_required: false }),
    patientValidationMessage: () => '',
    bookingSymptomsRequired,
    canOpenBooking: async () => true,
    checkAppAccess,
    canUseApp,
    uni: { hideKeyboard() {}, showToast({ title }) { messages.push(title) } },
  })
  await mount({ id: doctorId, date })
  form.setTime({ date, slot: '晚班' })
  return { ...form, schedule, messages, bookingSymptomsRequired, respondWith: value => { response = value }, requests: () => requests }
}

test('a cached calendar is refreshed before opening and an available selection is retained', async () => {
  const form = await openForm()
  let publish
  form.respondWith(new Promise(resolve => { publish = resolve }))
  const opening = form.selectTime()
  try {
    assert.equal(form.requests(), 1)
    assert.equal(form.picking.value, false)
  } finally {
    publish(days(night(1)))
    await opening
  }
  assert.equal(form.schedule.value[0].availability[doctorId][0].remaining, 1)
  assert.equal(form.selectedSlot.value, '晚班')
  assert.equal(form.picking.value, true)
})

test('a removed or full shift stays deselected when it becomes available again', async () => {
  for (const unavailable of [days(), days(night(0))]) {
    const form = await openForm()
    form.respondWith(unavailable)
    await form.selectTime()
    assert.equal(form.selectedSlot.value, '')
    form.picking.value = false

    form.respondWith(days(night(4)))
    await form.selectTime()
    assert.equal(form.requests(), 2)
    assert.equal(form.picking.value, true)
    assert.equal(form.selectedSlot.value, '')
  }
})

test('a failed refresh keeps the draft and allows a fresh retry', async () => {
  const form = await openForm()
  form.name.value = '测试就诊人'
  form.phone.value = '13800000000'
  form.symptoms.value = '测试症状'
  form.respondWith([])
  await form.selectTime()

  assert.equal(form.picking.value, false)
  assert.match(form.messages[0], /请重试/)
  assert.equal(form.name.value, '测试就诊人')
  assert.equal(form.phone.value, '13800000000')
  assert.equal(form.symptoms.value, '测试症状')

  form.respondWith(days(night(4)))
  await form.selectTime()
  assert.equal(form.picking.value, true)
  assert.equal(form.selectedSlot.value, '晚班')
})

test('required symptoms reject blank input in place and a completed draft can continue', async () => {
  const form = await openForm()
  form.bookingSymptomsRequired.value = true
  form.name.value = '测试就诊人'
  form.sex.value = '女'
  form.age.value = '30'
  form.phone.value = '13900000000'
  for (const blank of ['', ' \u3000 ']) {
    form.symptoms.value = blank
    await form.confirmBooking()
    assert.equal(form.messages.at(-1), '请填写症状描述')
    assert.deepEqual([form.doctor.value.id, form.date.value, form.selectedSlot.value,
      form.name.value, form.sex.value, form.age.value, form.phone.value, form.symptoms.value],
    [doctorId, date, '晚班', '测试就诊人', '女', '30', '13900000000', blank])
  }

  form.symptoms.value = '测试症状'
  await form.confirmBooking()
  assert.equal(form.messages.at(-1), '医院预约受理尚未开放')

  form.bookingSymptomsRequired.value = false
  form.symptoms.value = ''
  await form.confirmBooking()
  assert.deepEqual(form.messages, ['请填写症状描述', '请填写症状描述', '医院预约受理尚未开放', '医院预约受理尚未开放'])
})
