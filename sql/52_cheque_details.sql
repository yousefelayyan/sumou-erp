-- =====================================================================
--  السمو ERP — المرحلة 52: تفاصيل الشيك (اسم المجيّر، سبب الإرجاع)
--  الحقول وصفية بس (بتتعدّل بصلاحية تعديل الشيكات؛ الحماية cheques_guard بتمنع تغيير المبلغ والطرف والحالة).
-- =====================================================================
alter table public.cheques add column if not exists endorser_name text;
alter table public.cheques add column if not exists return_reason text;
