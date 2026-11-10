-- =====================================================================
--  نظام السمو ERP — إضافة صلاحية «ترحيل» لمجموعة المحاسب الجاهزة
--  (بس إذا ما انحددت من قبل). مدير النظام إله كل الصلاحيات دائماً.
-- =====================================================================
update public.user_groups g set permissions = (
  select jsonb_object_agg(k, case when k in ('journal_entries','receipt_vouchers','payment_vouchers','opening_balances','sales_invoices','purchase_invoices')
                                   and not (v ? 'post') then v || '{"post":true}'::jsonb else v end)
  from jsonb_each(g.permissions) as t(k, v))
where g.name = 'محاسب' and g.permissions <> '{}'::jsonb;

-- انتهى ✅
