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
const calendarSource = readFileSync(new URL('../pages/booking/booking-calendar.js', import.meta.url), 'utf8')
  .replace(/^import .*\n/gm, '').replace(/^export /gm, '')
const { bookingShifts, bookingSlotKey, bookingSlots, shiftBookable, shiftClosed, shiftSlots, nextBookableSlot } = new Script(
  `${calendarSource}\n({ bookingShifts, bookingSlotKey, bookingSlots, shiftBookable, shiftClosed, shiftSlots, nextBookableSlot })`)
  .runInNewContext({ computed })
const source = readFileSync(new URL('../pages/booking/form.vue', import.meta.url), 'utf8')
const setup = source.match(/<script setup>\s*([\s\S]*?)<\/script>/)[1].replace(/^import .*\n/gm, '')
// Run the page's handlers with the uni-app hooks and calendar store provided by the fixture.
const bookingForm = new Script(`${setup}\n({ selectTime, setTime, confirmBooking, picking, doctor, date, selectedSlot, name, sex, age, phone, symptoms })`)

async function openForm(initial = days(night(4))) {
  const schedule = ref(initial)
  const now = ref(Date.parse('2026-11-30T07:00:00+08:00'))
  const selectedDate = ref('')
  const selectedDay = computed(() => schedule.value.find(day => day.date === selectedDate.value) || schedule.value[0])
  const bookingSymptomsRequired = ref(false)
  const messages = []
  let mount
  let response = initial
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
    useBookingCalendar: () => ({ schedule, selectedDate, selectedDay, refresh() {}, now, refreshClock() {} }),
    bookingSlotKey, bookingSlots,
    shiftBookable,
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
  form.setTime({ doctorId, date, slot: bookingSlots(schedule.value[0], doctorId)[0] })
  return { ...form, schedule, now, messages, bookingSymptomsRequired, respondWith: value => { response = value }, requests: () => requests }
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
  assert.equal(form.selectedSlot.value.label, '晚班')
  assert.equal(form.picking.value, true)
})

test('a removed or full shift stays deselected when it becomes available again', async () => {
  for (const unavailable of [days(), days(night(0))]) {
    const form = await openForm()
    form.respondWith(unavailable)
    await form.selectTime()
    assert.equal(form.selectedSlot.value, null)
    form.picking.value = false

    form.respondWith(days(night(4)))
    await form.selectTime()
    assert.equal(form.requests(), 2)
    assert.equal(form.picking.value, true)
    assert.equal(form.selectedSlot.value, null)
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
  assert.equal(form.selectedSlot.value.label, '晚班')
})

test('the next shift and the date filter agree on cutoff, remaining seats and days off', () => {
  const cutoff = Date.parse('2026-11-30T12:00:00+08:00')
  const nextDate = '2026-12-01'
  const morning = cutoff_at => ({ time_slot: 'AM', label: '上午', total: 25, remaining: 25, cutoff_at })
  const todayShift = morning(cutoff)
  const tonight = { ...night(4), cutoff_at: cutoff + 9 * 3_600_000 }
  const fullDay = { date: nextDate, availability: { [doctorId]: [{ ...morning(cutoff + 86_400_000), remaining: 0 }] } }
  const dayOff = { date: '2026-12-02', availability: {} }
  const props = { schedule: [...days(todayShift, tonight), fullDay, dayOff], doctorId, date, now: cutoff - 1000 }
  let now = props.now
  let update
  const confirmations = []
  const source = readFileSync(new URL('../pages/booking/components/slot_picker.vue', import.meta.url), 'utf8')
  const setup = source.match(/<script setup>\s*([\s\S]*?)<\/script>/)[1].replace(/^import .*\n/gm, '')
  const picker = new Script(`${setup}\n({ selectSlot, onlyBookable, visibleDays, canConfirm, choice, shiftText, confirm })`).runInNewContext({
    computed, ref, bookingShifts, bookingSlotKey, bookingSlots, shiftBookable, shiftClosed, shiftSlots, Date: { now: () => now },
    watch(sources, handler) { update = () => handler(sources.map(source => source.value)) },
    defineProps: () => props, defineEmits: () => (_event, selection) => confirmations.push(selection),
  })

  assert.equal(picker.visibleDays.value.length, 3)
  assert.equal(nextBookableSlot(props.schedule, doctorId, now).slot.label, '上午')
  picker.selectSlot(todayShift)
  assert.equal(picker.canConfirm.value, true)
  now = cutoff
  picker.confirm()
  assert.deepEqual(confirmations, [])
  props.now = now
  picker.onlyBookable.value = true
  update()
  assert.equal(picker.visibleDays.value.length, 1)
  assert.equal(picker.visibleDays.value[0].date, date)
  assert.equal(picker.canConfirm.value, false)
  assert.equal(picker.choice.value, '')
  assert.match(picker.shiftText(todayShift), /已截止/)
  assert.equal(nextBookableSlot(props.schedule, doctorId, now).slot.label, '晚班')
  picker.selectSlot(tonight)
  picker.confirm()
  assert.deepEqual(confirmations.map(selection => [selection.doctorId, selection.date, selection.slot.time_slot]), [[doctorId, date, 'NIGHT']])

  now = props.now = tonight.cutoff_at
  update()
  assert.equal(picker.visibleDays.value.length, 0)
  assert.equal(picker.canConfirm.value, false)
  assert.equal(nextBookableSlot(props.schedule, doctorId, now), undefined)
  picker.onlyBookable.value = false
  update()
  assert.equal(picker.visibleDays.value.length, 3)
  assert.equal(picker.choice.value, '')

  const later = { date: '2026-12-03', availability: { [doctorId]: [morning(cutoff + 3 * 86_400_000)] } }
  props.schedule = [...props.schedule, later]
  picker.onlyBookable.value = true
  update()
  assert.equal(picker.visibleDays.value[0].date, later.date)
  assert.equal(nextBookableSlot(props.schedule, doctorId, now).day.date, later.date)
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
    assert.deepEqual([form.doctor.value.id, form.date.value, form.selectedSlot.value.label,
      form.name.value, form.sex.value, form.age.value, form.phone.value, form.symptoms.value],
    [doctorId, date, '晚班', '测试就诊人', '女', '30', '13900000000', blank])
  }

  form.symptoms.value = '测试症状'
  await form.confirmBooking()
  assert.equal(form.messages.at(-1), '医院预约受理尚未开放')

  form.symptoms.value = ''
  form.respondWith(Promise.resolve(days(night(4))).then(result => {
    form.bookingSymptomsRequired.value = false
    return result
  }))
  await form.confirmBooking()
  assert.deepEqual(form.messages, ['请填写症状描述', '请填写症状描述', '医院预约受理尚未开放', '医院预约受理尚未开放'])

  form.respondWith(Promise.resolve(days(night(4))).then(result => {
    form.bookingSymptomsRequired.value = true
    return result
  }))
  await form.confirmBooking()
  assert.equal(form.messages.at(-1), '请填写症状描述')
  assert.equal(form.selectedSlot.value.label, '晚班')
  assert.equal(form.name.value, '测试就诊人')
  assert.equal(form.phone.value, '13900000000')
})

test('a timed selection uses its exact shift and times and refreshes without clearing the patient draft', async () => {
  const cutoff_at = Date.parse('2026-11-30T11:30:00+08:00')
  const lastSlot = { start_time: '11:30', end_time: '12:00', cutoff_at, remaining: 1, shift_available: 1 }
  const morning = { time_slot: 'AM', label: '上午', total: 37, remaining: 12, slots: [lastSlot] }
  const calendar = days(morning)
  const form = await openForm(calendar)
  form.name.value = '测试就诊人'
  form.sex.value = '女'
  form.age.value = '30'
  form.phone.value = '13800000000'
  form.symptoms.value = '测试症状'

  const latest = nextBookableSlot(calendar, doctorId, cutoff_at - 1000).slot
  assert.equal(latest.label, '11:30–12:00')
  assert.equal(latest.remaining, 1)
  assert.equal(bookingSlotKey(form.selectedSlot.value), 'AM/slot/11:30/12:00')
  form.now.value = cutoff_at
  assert.equal(nextBookableSlot(calendar, doctorId, cutoff_at), undefined)
  assert.equal(form.selectedSlot.value, null)

  form.now.value = cutoff_at - 1000
  form.respondWith([])
  await form.confirmBooking()
  assert.match(form.messages.at(-1), /排班暂不可用，请重试/)
  assert.equal(form.selectedSlot.value, null)
  form.respondWith(days({ ...morning, time_slot: 'PM' }))
  await form.confirmBooking()
  assert.equal(form.selectedSlot.value, null)
  assert.equal(form.messages.at(-1), '时段已不可约，请重新选择')
  assert.deepEqual([form.name.value, form.sex.value, form.age.value, form.phone.value, form.symptoms.value],
    ['测试就诊人', '女', '30', '13800000000', '测试症状'])
})
