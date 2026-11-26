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
const bookingForm = new Script(`${setup}\n({ selectTime, setTime, picking, selectedSlot, name, phone, symptoms })`)

async function openForm() {
  const schedule = ref(days(night(4)))
  const selectedDate = ref('')
  const selectedDay = computed(() => schedule.value.find(day => day.date === selectedDate.value) || schedule.value[0])
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
    findBookingDoctor: id => ({ id }),
    useBookingCalendar: () => ({ schedule, selectedDate, selectedDay, refresh() {} }),
    bookingShifts: (day, id) => day?.availability?.[id] ?? [],
    signedIn: ref(true),
    loadPatients: async () => [],
    readProfile: async () => null,
    canOpenBooking: async () => true,
    checkAppAccess,
    canUseApp,
    uni: { hideKeyboard() {}, showToast({ title }) { messages.push(title) } },
  })
  await mount({ id: doctorId, date })
  form.setTime({ date, slot: '晚班' })
  return { ...form, schedule, messages, respondWith: value => { response = value }, requests: () => requests }
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
