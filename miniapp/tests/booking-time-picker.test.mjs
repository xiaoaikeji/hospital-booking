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
const bookingForm = new Script(`${setup}\n({ selectTime, setTime, confirmBooking, verifyPhone, picking, doctor, date, selectedSlot, needsBinding, checkingBinding, canAuthorizePhone, name, sex, age, phone, symptoms, pendingBooking, departmentName, chooseDepartment, setDepartment })`)
const orderNo = '20261130090000000001'
const NO_BOOKABLE_DEPARTMENT = '该医生暂无可预约科室'
const bookingError = (code, message) => Object.assign(new Error(message), { code, statusCode: 422 })

async function openForm(initial = days(night(4)), { departmentIds = ['1'], sourceDepartment } = {}) {
  const schedule = ref(initial)
  const now = ref(Date.parse('2026-11-30T07:00:00+08:00'))
  const selectedDate = ref('')
  const selectedDay = computed(() => schedule.value.find(day => day.date === selectedDate.value) || schedule.value[0])
  const bookingSymptomsRequired = ref(false)
  const messages = []
  let mount
  let resume
  let suspend
  let phoneRequired = false
  let symptomsRequired = false
  let checkResponse
  let bindings = 0
  const checks = []
  const submissions = []
  const navigation = []
  const configurationRefreshes = []
  let response = initial
  let submitResult
  let serial = 0
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
    onShow(handler) { resume = handler },
    onHide(handler) { suspend = handler },
    onUnload() {},
    directoryDemoMode: false,
    demoMode: false,
    findBookingDoctor: id => ({ id, department_ids: departmentIds }),
    bookingDepartments: ref(departmentIds.map(id => ({ id, name: '科室' + id }))),
    useBookingCalendar: () => ({ schedule, selectedDate, selectedDay, refresh() {}, now, refreshClock() {} }),
    bookingSlotKey, bookingSlots,
    shiftBookable,
    signedIn: ref(true),
    loadPatients: async () => [],
    readProfile: async () => ({ booking_phone_required: phoneRequired }),
    async requestForUser(path, { data }) {
      assert.equal(path, 'appointment_check')
      checks.push({ ...data })
      return checkResponse ?? { bookable: true, booking_phone_required: phoneRequired, booking_symptoms_required: symptomsRequired }
    },
    newBookingKey: () => 'fixture-booking-key-' + ++serial,
    async submitAppointment(data) {
      submissions.push({ ...data })
      if (submitResult) return await submitResult()
      if (symptomsRequired && !data.remark.trim()) throw bookingError('symptoms_required', '请填写症状描述')
      if (phoneRequired) throw bookingError('phone_required', '请先验证账号手机号')
      return { order_no: orderNo, outcome: 'created' }
    },
    refreshAppConfiguration(options) { configurationRefreshes.push({ ...options }) },
    NO_BOOKABLE_DEPARTMENT,
    async bindPhone() { bindings++; return { mobile: '10000000001' } },
    nextTick: async () => {},
    patientValidationMessage: () => '',
    bookingSymptomsRequired,
    canOpenBooking: async () => true,
    checkAppAccess,
    canUseApp,
    uni: { hideKeyboard() {}, pageScrollTo() {}, showToast({ title }) { messages.push(title) },
      async navigateTo({ url }) { navigation.push(url) } },
  })
  await mount({ id: doctorId, date, department_id: sourceDepartment })
  form.setTime({ doctorId, date, slot: bookingSlots(schedule.value[0], doctorId)[0] })
  return { ...form, schedule, now, messages, resume, suspend, checks, submissions, navigation, configurationRefreshes, bindings: () => bindings,
    respondToCheck: value => { checkResponse = value },
    respondToSubmit: handler => { submitResult = handler },
    setPhoneRequired: value => { phoneRequired = value },
    setSymptomsRequired: value => { symptomsRequired = value },
    respondWith: value => { response = value }, requests: () => requests }
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
    computed, ref, bookingShifts, bookingSlotKey, bookingSlots, shiftBookable, shiftClosed, shiftSlots, bookingNow: () => now,
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
  form.setSymptomsRequired(true)
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
  assert.deepEqual(form.messages, ['请填写症状描述', '请填写症状描述'])
  assert.deepEqual(form.navigation, ['/pages/ucenter/appointment_detail?created=1&no=' + orderNo])
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
  form.respondToSubmit(() => { throw new Error('网络连接失败，请重试') })
  await form.confirmBooking()
  assert.match(form.messages.at(-1), /网络连接失败，请重试/)
  assert.equal(form.selectedSlot.value.label, '11:30–12:00')
  form.respondToSubmit(() => { throw bookingError('slot_closed', '该时段已截止，请重新选择') })
  await form.confirmBooking()
  assert.equal(form.selectedSlot.value, null)
  assert.equal(form.messages.at(-1), '该时段已截止，请重新选择')
  assert.deepEqual(form.submissions[0], form.submissions[1])
  assert.deepEqual([form.name.value, form.sex.value, form.age.value, form.phone.value, form.symptoms.value],
    ['测试就诊人', '女', '30', '13800000000', '测试症状'])
})

test('a click after cutoff checks its selection while a foreground calendar reply is still pending', async () => {
  const cutoff_at = Date.parse('2026-11-30T11:30:00+08:00')
  const slot = { start_time: '11:30', end_time: '12:00', cutoff_at, remaining: 1, shift_available: 1 }
  const old = days({ time_slot: 'AM', total: 37, remaining: 12, slots: [slot] })
  const form = await openForm(old)
  form.now.value = cutoff_at - 2000
  let publish
  form.respondWith(new Promise(resolve => { publish = resolve }))
  form.resume()
  assert.equal(form.requests(), 1)
  assert.equal(form.selectedSlot.value.label, '11:30–12:00')
  form.respondToSubmit(() => { throw bookingError('slot_closed', '该时段已截止，请重新选择') })
  await form.confirmBooking()
  const { doctor_id, time_slot, mode, start_time, end_time } = form.submissions[0]
  assert.deepEqual([doctor_id, time_slot, mode, start_time, end_time], [doctorId, 'AM', 'slot', '11:30', '12:00'])
  assert.equal(form.messages.at(-1), '该时段已截止，请重新选择')
  publish(old)
  assert.equal(form.selectedSlot.value, null)
})

test('resuming a form refreshes a pending phone authorization and preserves the draft', async () => {
  const form = await openForm()
  form.name.value = '测试就诊人'
  form.phone.value = '13800000000'
  form.symptoms.value = '测试症状'

  form.setPhoneRequired(true)
  await form.confirmBooking()
  assert.equal(form.needsBinding.value, true)
  assert.equal(form.canAuthorizePhone.value, true)
  form.suspend()
  assert.equal(form.canAuthorizePhone.value, false)
  let publish
  form.respondToCheck(new Promise(resolve => { publish = resolve }))
  const resumed = form.resume()
  assert.equal(form.checkingBinding.value, true)
  await form.verifyPhone({ code: 'test-code' })
  assert.equal(form.bindings(), 0)
  publish({ bookable: true, booking_phone_required: true, booking_symptoms_required: false })
  await resumed
  assert.equal(form.checkingBinding.value, false)
  assert.equal(form.needsBinding.value, true)
  assert.equal(form.canAuthorizePhone.value, true)

  form.setPhoneRequired(false)
  form.respondToCheck(null)
  form.suspend()
  await form.resume()
  assert.equal(form.needsBinding.value, false)
  assert.equal(form.selectedSlot.value.label, '晚班')
  await form.confirmBooking()
  assert.deepEqual(form.navigation, ['/pages/ucenter/appointment_detail?created=1&no=' + orderNo])
  assert.deepEqual([form.name.value, form.phone.value, form.symptoms.value], ['测试就诊人', '13800000000', '测试症状'])
})

test('a lost response retries the identical submission even after the seat is gone', async () => {
  const form = await openForm()
  form.respondToSubmit(() => { throw new Error('网络连接失败，请重试') })
  await form.confirmBooking()
  form.schedule.value = days(night(0))
  assert.equal(form.selectedSlot.value, null)
  form.respondToSubmit(() => ({ order_no: orderNo, outcome: 'replayed' }))
  await form.confirmBooking()
  assert.deepEqual(form.submissions[0], form.submissions[1])
  assert.deepEqual(form.navigation, ['/pages/ucenter/appointment_detail?created=1&no=' + orderNo])
  assert.deepEqual(form.configurationRefreshes, [{ fresh: true }])
})

test('the original form uses a valid source department or asks the patient to pick one', async () => {
  const ids = ['1', '2']
  const fromDepartment = await openForm(undefined, { departmentIds: ids, sourceDepartment: '2' })
  assert.equal(fromDepartment.departmentName.value, '科室2')
  assert.equal(fromDepartment.chooseDepartment.value, false)

  const direct = await openForm(undefined, { departmentIds: ids, sourceDepartment: '3' })
  assert.equal(direct.chooseDepartment.value, true)
  await direct.confirmBooking()
  assert.equal(direct.messages.at(-1), '请选择科室')
  assert.equal(direct.submissions.length, 0)
  direct.setDepartment({ detail: { value: '1' } })
  await direct.confirmBooking()
  assert.equal(direct.submissions[0].department_id, '2')
})

test('a doctor remains viewable while booking entries with no department are stopped', async () => {
  const source = readFileSync(new URL('../utils/booking-navigation.js', import.meta.url), 'utf8')
    .replace(/^import .*\n/gm, '').replace(/^export /gm, '')
  const links = []
  const toasts = []
  const pages = [{ route: 'pages/booking/form' }]
  const navigation = new Script(`${source}\n({ openBooking, canOpenBooking })`).runInNewContext({
    signedIn: ref(true), directoryDemoMode: false, findBookingDoctor: () => ({ department_ids: [] }),
    canUseApp: async () => true, getCurrentPages: () => pages,
    uni: { navigateTo({ url }) { links.push(url) }, redirectTo({ url }) { links.push(url) }, showToast({ title }) { toasts.push(title) } },
  })
  const context = { id: doctorId }
  navigation.openBooking('doctor', context)
  navigation.openBooking('form', context)
  assert.deepEqual(links, ['/pages/booking/doctor?id=' + doctorId])
  assert.deepEqual(toasts, [NO_BOOKABLE_DEPARTMENT])
  assert.equal(await navigation.canOpenBooking('form', context), false)
  assert.equal(links.at(-1), '/pages/booking/doctor?id=' + doctorId)

  const form = await openForm(undefined, { departmentIds: [] })
  await form.selectTime()
  await form.confirmBooking()
  assert.equal(form.picking.value, false)
  assert.deepEqual(form.submissions, [])
  assert.deepEqual(form.messages, [NO_BOOKABLE_DEPARTMENT, NO_BOOKABLE_DEPARTMENT])
})

function clockStore(loadAppConfiguration, deviceNow) {
  const source = readFileSync(new URL('../store/app-configuration.js', import.meta.url), 'utf8')
    .replace(/^import .*\n/gm, '').replace(/^export /gm, '')
  return new Script(`${source}\n;({ bookingClock, bookingNow, bookingSchedule, configurationStatus, refreshAppConfiguration })`)
    .runInNewContext({ computed, ref, loadAppConfiguration, Date: { now: deviceNow } })
}

test('after a booking only the new schedule response can publish the last seat', async () => {
  const time = Date.parse('2026-11-30T08:00:00+08:00')
  const response = remaining => ({
    status: 'ready', config: { server_time: time, schedule_refresh_at: time + 86_400_000, schedule: days(night(remaining)) },
  })
  let requests = 0
  let releaseOld, releaseNew
  const replies = [response(1), new Promise(resolve => { releaseOld = resolve }), new Promise(resolve => { releaseNew = resolve })]
  const store = clockStore(async () => await replies[requests++], () => time)
  await store.refreshAppConfiguration()
  const old = store.refreshAppConfiguration()
  const fresh = store.refreshAppConfiguration({ fresh: true })
  assert.equal(requests, 3)
  assert.equal(store.bookingSchedule.value.length, 0)
  releaseNew(response(0))
  await fresh
  releaseOld(response(1))
  await old
  assert.equal(store.bookingSchedule.value[0].availability[doctorId][0].remaining, 0)
})

test('device clock offsets of either sign do not affect the countdown from the server sample', async () => {
  const start = Date.parse('2026-11-30T11:29:00+08:00')
  const cutoff_at = start + 60_000
  const shift = { remaining: 1, cutoff_at }
  for (const offset of [-120_000, 120_000]) {
    let deviceTime = start + offset
    const store = clockStore(async () => ({status: 'ready', config: {
      server_time: start, schedule_refresh_at: Date.parse('2026-12-01T00:00:00+08:00'), schedule: days(shift),
    }}), () => deviceTime)
    await store.refreshAppConfiguration()
    assert.equal(store.bookingNow(), start)
    assert.equal(shiftBookable(shift, store.bookingNow()), true)
    deviceTime += 60_000
    assert.equal(store.bookingNow(), cutoff_at)
    assert.equal(shiftBookable(shift, store.bookingNow()), false)
  }
})

test('a late calendar reply does not reopen a slot the displayed clock already closed', async () => {
  const cutoff_at = Date.parse('2026-11-30T11:30:00+08:00')
  const shift = { remaining: 1, cutoff_at }
  const config = { schedule_refresh_at: cutoff_at + 12 * 3_600_000, schedule: days(shift) }
  let deviceTime = cutoff_at - 4000
  let result = { status: 'ready', config: { ...config, server_time: deviceTime } }
  const store = clockStore(async () => await result, () => deviceTime)
  await store.refreshAppConfiguration()
  deviceTime += 1000
  let publish
  result = new Promise(resolve => { publish = resolve })
  const pending = store.refreshAppConfiguration()
  deviceTime = cutoff_at + 1000
  assert.equal(shiftBookable(shift, store.bookingNow()), false)
  publish({ status: 'ready', config: { ...config, server_time: cutoff_at - 2000 } })
  await pending
  assert.equal(store.bookingNow(), cutoff_at + 1000)
  assert.equal(shiftBookable(shift, store.bookingNow()), false)
})

test('the active calendar refreshes at Beijing midnight and retries after a failed refresh', async () => {
  const midnight = Date.parse('2026-12-01T00:00:00+08:00')
  let deviceTime = midnight + 119_000
  let result = { status: 'ready', config: {
    server_time: midnight - 1000, schedule_refresh_at: midnight, schedule: days(),
  } }
  const store = clockStore(async () => await result, () => deviceTime)
  let show, hide, clockChanged, nextTick, delay, request
  let refreshes = 0
  const calendar = new Script(`${calendarSource}\nuseBookingCalendar(() => false)`).runInNewContext({
    ...store, computed, ref,
    checkAppAccess() { refreshes++; request = store.refreshAppConfiguration() },
    onShow(handler) { show = handler }, onHide(handler) { hide = handler }, onUnload() {},
    watch(_clock, handler) { clockChanged = handler },
    setTimeout(handler, ms) { nextTick = handler; delay = ms }, clearTimeout() { nextTick = undefined },
  })
  await store.refreshAppConfiguration()
  show()
  assert.equal(delay, 1000)
  assert.equal(refreshes, 0)

  deviceTime += 1000
  result = { status: 'error' }
  nextTick()
  await request
  assert.equal(refreshes, 1)
  assert.equal(calendar.schedule.value.length, 0)
  assert.equal(delay, 60_000)

  deviceTime += 60_000
  let publish
  result = new Promise(resolve => { publish = resolve })
  nextTick()
  assert.equal(calendar.schedule.value.length, 0)
  const lastDate = '2026-12-14'
  publish({ status: 'ready', config: {
    server_time: midnight + 60_000, schedule_refresh_at: midnight + 86_400_000,
    schedule: [{ date: '2026-12-01', availability: {} }, { date: lastDate, availability: { [doctorId]: [night(1)] } }],
  } })
  await request
  clockChanged()
  assert.equal(refreshes, 2)
  assert.equal(nextBookableSlot(calendar.schedule.value, doctorId, calendar.now.value).day.date, lastDate)
  hide()
  assert.equal(nextTick, undefined)
})
