# Shared media uploads

Call `MediaUpload.new(file, as: purpose).create_blob!` to store a validated upload using the configured Active Storage service. `MediaUpload.attach(file, as: purpose) { |blob| ... }` also removes an unattached new blob if the business operation fails. The original filename stays in blob metadata; object names use a seconds timestamp, six content MD5 characters and a lowercase extension. Database reservations and storage checks avoid overwriting existing objects.

Purposes define allowed extensions, detected content types and size limits. Location pictures and poster backgrounds allow JPG/JPEG/PNG/WEBP up to 10 MB; WeChat credentials and avatars allow JPG/JPEG/PNG up to 2 MB. Menu images, voice and video preserve their respective WeChat restrictions.

For files sent directly to WeChat, callers validate with their own purpose (`wechat_avatar` for avatars, `wechat_certificate` for category certificates, `menu_*` for official-account materials) using `validate!`, `content_type` and `filename` without creating a local blob, then pass the validated file, detected content type and generated filename to the existing platform client for transfer without re-validating in the client. `MediaUpload::Invalid` contains a validation message; `MediaUpload::Failed` contains a safe storage failure message. Callers translate these into their own form/API errors.
