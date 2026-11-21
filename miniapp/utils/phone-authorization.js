const DECLINED = /^getPhoneNumber:fail[: ]+(?:user )?(?:deny|denied|cancel|cancelled)$/i

export function phoneAuthorizationOutcome(detail) {
  const { code, errMsg } = detail ?? {}
  if (errMsg === 'getPhoneNumber:ok' && typeof code === 'string' && code.trim()) return 'authorized'
  if (DECLINED.test(errMsg)) return 'denied'
  return 'failed'
}
