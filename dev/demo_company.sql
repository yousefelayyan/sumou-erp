-- =====================================================================
--  شركة تجريبية «عالم الشخصيات للاكسسوارات والهدايا» ببيانات كاملة للفحص
--  بتنعمل باسم مدير المنصة (أو أول مدير) وبتمشي على كل الصلاحيات والـ triggers زي البرنامج.
--  للحذف بعدين: dev/demo_company_delete.sql
-- =====================================================================
select set_config('request.jwt.claim.sub',
  coalesce((select id::text from public.profiles where is_super and is_active order by created_at limit 1),
           (select id::text from public.profiles where is_admin and is_active order by created_at limit 1)), false);
set role authenticated;

do $demo$
declare
  co uuid; fy uuid; uid uuid := auth.uid();
  d_main uuid; d_sh uuid; d_mm uuid; w1 uuid; w2 uuid; cc1 uuid; cc2 uuid;
  a_cash uuid; a_bank uuid; a_ar uuid; a_ap uuid; a_cap uuid; a_furn uuid; a_pc uuid; a_acc uuid;
  r1 uuid; r2 uuid; cat_c1 uuid; cat_c2 uuid; cat_s uuid;
  e uuid; inv uuid; sd uuid; run uuid; o uuid; lid uuid; x jsonb; ln jsonb; i int; n int;
  it jsonb := '[
    ["I001","مجسم شخصية كرتونية 15 سم","01",4.5,9],
    ["I002","مجسم شخصية أنمي 20 سم","01",7,14],
    ["I003","ميدالية مفاتيح شخصيات","02",0.6,1.5],
    ["I004","سلسال وأسوارة شخصيات فضة","02",2.5,6],
    ["I005","حقيبة ظهر مطبوعة شخصيات","02",8,16],
    ["I006","كوب سيراميك مطبوع","03",2,4.5],
    ["I007","دفتر ملاحظات شخصيات","03",1.2,3],
    ["I008","علبة هدايا مغلّفة جاهزة","03",3.5,8],
    ["I009","دبدوب محشو 30 سم","04",5,11],
    ["I010","ستيكرات مجموعة 50 قطعة","02",0.4,1.25],
    ["I011","قبعة مطبوعة شخصيات","02",2.8,6.5],
    ["I012","ورق تغليف هدايا (لفة)","05",0.3,1]]';
  pid jsonb := '{}'; iid jsonb := '{}';
begin
  if uid is null then raise exception 'ما في مستخدم مدير'; end if;
  if exists (select 1 from public.companies where name = 'عالم الشخصيات للاكسسوارات والهدايا') then
    raise exception 'الشركة التجريبية موجودة من قبل';
  end if;

  -- 1) الشركة والسنة والدليل والإعدادات
  insert into public.companies (code, name, trade_name, company_type, activity_type, city, address, phone, mobile, email,
                                subject_to_sales_tax, sales_tax_period, sales_tax_no, national_no, notes, created_by)
  values ('99', 'عالم الشخصيات للاكسسوارات والهدايا', 'عالم الشخصيات', 'مؤسسة فردية', 'تجارة اكسسوارات وهدايا', 'عمّان',
          'الشميساني - شارع عبد الحميد شرف', '065600000', '0790000000', 'info@shakhsiyat.jo',
          true, 'bimonthly', '123456789', '200000001', 'شركة تجريبية للفحص — بتنحذف بعدين', uid);
  select id into co from public.companies where name = 'عالم الشخصيات للاكسسوارات والهدايا' and created_by = uid;
  insert into public.fiscal_years (company_id, code, name, start_date, end_date) values (co, '2026', 'السنة المالية 2026', '2026-01-01', '2026-12-31') returning id into fy;
  perform public.seed_default_accounts(co);
  perform public.ensure_company_settings(co);
  perform public.ensure_payroll_settings(co);
  perform public.ensure_doc_types(co);
  select id into a_cash from public.accounts where company_id = co and code = '1101';
  select id into a_bank from public.accounts where company_id = co and code = '1102';
  select id into a_ar   from public.accounts where company_id = co and code = '1103';
  select id into a_ap   from public.accounts where company_id = co and code = '2101';
  select id into a_cap  from public.accounts where company_id = co and code = '3101';
  select id into a_furn from public.accounts where company_id = co and code = '1203';
  select id into a_pc   from public.accounts where company_id = co and code = '1206';
  select id into a_acc  from public.accounts where company_id = co and code = '1209';
  update public.accounts set name = 'البنك العربي - حساب جاري' where id = a_bank;
  -- جرد مستمر
  update public.company_settings set perpetual_inventory = true,
    inventory_account_id = (select id from public.accounts where company_id = co and code = '1105'),
    cogs_account_id = (select id from public.accounts where company_id = co and code = '5104')
  where company_id = co;

  -- 2) الدوائر والمستودعات ومراكز الكلفة
  insert into public.warehouses (company_id, code, name) values (co, 'W01', 'المستودع الرئيسي - الشميساني') returning id into w1;
  insert into public.warehouses (company_id, code, name) values (co, 'W02', 'مستودع فرع مكة مول') returning id into w2;
  insert into public.cost_centers (company_id, code, name) values (co, 'CC01', 'المعرض') returning id into cc1;
  insert into public.cost_centers (company_id, code, name) values (co, 'CC02', 'البيع أونلاين') returning id into cc2;
  insert into public.departments (company_id, code, name, kind) values (co, '01', 'الإدارة العامة', 'main') returning id into d_main;
  insert into public.departments (company_id, code, name, kind, parent_id, warehouse_id, cost_center_id, city)
    values (co, '0101', 'معرض الشميساني', 'sub', d_main, w1, cc1, 'عمّان') returning id into d_sh;
  insert into public.departments (company_id, code, name, kind, parent_id, warehouse_id, cost_center_id, city)
    values (co, '0102', 'فرع مكة مول', 'sub', d_main, w2, cc1, 'عمّان') returning id into d_mm;

  -- 3) فئات المواد والأصناف
  insert into public.item_categories (company_id, code, name) values
    (co, '01', 'مجسمات وشخصيات'), (co, '02', 'اكسسوارات'), (co, '03', 'هدايا'), (co, '04', 'ألعاب محشوة'), (co, '05', 'تغليف');
  for i in 0 .. jsonb_array_length(it) - 1 loop
    x := it -> i;
    insert into public.items (company_id, code, name, unit, barcode, purchase_price, sale_price, tax_rate, track_stock, category_id)
    values (co, x ->> 0, x ->> 1, 'حبة', '62500000' || lpad((i + 1)::text, 4, '0'), (x ->> 3)::numeric, (x ->> 4)::numeric, 16, true,
            (select id from public.item_categories where company_id = co and code = x ->> 2))
    returning jsonb_build_object(x ->> 0, id) || iid into iid;
  end loop;

  -- 4) المندوبين وفئات العملاء والعملاء والموردين وبطاقات المصاريف
  insert into public.lookups (company_id, kind, code, name, rate) values (co, 'sales_rep', 'R01', 'أحمد العلي', 2) returning id into r1;
  insert into public.lookups (company_id, kind, code, name, rate) values (co, 'sales_rep', 'R02', 'ليث حداد', 1.5) returning id into r2;
  insert into public.party_categories (company_id, party_type, code, name) values (co, 'customer', '01', 'عملاء جملة') returning id into cat_c1;
  insert into public.party_categories (company_id, party_type, code, name) values (co, 'customer', '02', 'عملاء مفرق') returning id into cat_c2;
  insert into public.party_categories (company_id, party_type, code, name) values (co, 'supplier', '01', 'موردين محليين') returning id into cat_s;
  for x in select * from jsonb_array_elements('[
      ["C0001","محل لمسة فن للهدايا","إربد","0791111111",3000,"1"],
      ["C0002","مكتبة الطالب الحديثة","الزرقاء","0792222222",2500,"1"],
      ["C0003","متجر بيبي ستار","عمّان","0793333333",2000,"2"],
      ["C0004","زبون نقدي","عمّان","",0,"0"],
      ["C0005","شركة الفرح لتنظيم المناسبات","عمّان","0795555555",4000,"1"],
      ["C0006","سارة محمود (طلبات أونلاين)","السلط","0796666666",0,"0"]]') loop
    insert into public.parties (company_id, party_type, code, name, city, mobile, account_id, credit_limit, payment_terms_days, category_id, sales_rep_id)
    values (co, 'customer', x ->> 0, x ->> 1, x ->> 2, nullif(x ->> 3, ''), a_ar, (x ->> 4)::numeric, 30,
            case when x ->> 5 = '0' then cat_c2 else cat_c1 end, case x ->> 5 when '1' then r1 when '2' then r2 end)
    returning jsonb_build_object(x ->> 0, id) || pid into pid;
  end loop;
  for x in select * from jsonb_array_elements('[
      ["S0001","مؤسسة النجمة للاستيراد","عمّان - سحاب","0781111111"],
      ["S0002","شركة الشرق للألعاب والهدايا","العقبة","0782222222"],
      ["S0003","مطبعة الأفق","عمّان - المقابلين","0783333333"],
      ["S0004","مستودعات الريان للتغليف","الزرقاء","0784444444"]]') loop
    insert into public.parties (company_id, party_type, code, name, city, mobile, account_id, payment_terms_days, category_id)
    values (co, 'supplier', x ->> 0, x ->> 1, x ->> 2, x ->> 3, a_ap, 45, cat_s)
    returning jsonb_build_object(x ->> 0, id) || pid into pid;
  end loop;
  for x in select * from jsonb_array_elements('[["E0001","إيجار المعرض","5203"],["E0002","كهرباء ومياه المعرض","5204"],["E0003","إنترنت وهاتف","5205"],["E0004","إعلانات فيسبوك وانستغرام","5301"]]') loop
    insert into public.parties (company_id, party_type, code, name, account_id)
    values (co, 'expense', x ->> 0, x ->> 1, (select id from public.accounts where company_id = co and code = x ->> 2))
    returning jsonb_build_object(x ->> 0, id) || pid into pid;
  end loop;

  -- 5) الأصول الثابتة والقيد الافتتاحي
  insert into public.fixed_assets (company_id, code, name, category, purchase_date, dep_start, cost, salvage, life_months, opening_accum,
                                   asset_account_id, accum_account_id, expense_account_id, cost_center_id, location, department_id)
  values (co, 'A001', 'ديكور ورفوف المعرض', 'أثاث', '2025-01-01', '2026-01-01', 6000, 0, 60, 1200, a_furn, a_acc,
          (select id from public.accounts where company_id = co and code = '5213'), cc1, 'معرض الشميساني', d_sh),
         (co, 'A002', 'جهاز كاشير وحاسوب', 'حاسوب', '2025-01-01', '2026-01-01', 2500, 0, 36, 833.333, a_pc, a_acc,
          (select id from public.accounts where company_id = co and code = '5213'), cc1, 'معرض الشميساني', d_sh);
  insert into public.journal_entries (company_id, fiscal_year_id, entry_type, entry_date, description)
  values (co, fy, 'opening', '2026-01-01', 'الأرصدة الافتتاحية لسنة 2026') returning id into e;
  insert into public.journal_lines (entry_id, line_no, account_id, debit, credit, description) values
    (e, 1, a_cash, 3000, 0, 'نقد بالصندوق'), (e, 2, a_bank, 25000, 0, 'رصيد البنك العربي'),
    (e, 3, a_furn, 6000, 0, 'ديكور ورفوف'), (e, 4, a_pc, 2500, 0, 'أجهزة حاسوب'),
    (e, 5, a_acc, 0, 2033.333, 'مجمع الاستهلاك لنهاية 2025'), (e, 6, a_cap, 0, 34466.667, 'رأس المال');
  perform public.post_entry(e);

  -- 6) الموظفين
  insert into public.employees (company_id, code, name, job_title, department, hire_date, basic_salary, allowances, ss_subject, mobile, cost_center_id) values
    (co, 'EMP001', 'محمد خالد', 'مدير المعرض', 'المبيعات', '2025-01-01', 600, 50, true, '0771111111', cc1),
    (co, 'EMP002', 'رنا يوسف', 'بائعة', 'المبيعات', '2025-03-01', 380, 0, true, '0772222222', cc1),
    (co, 'EMP003', 'عمر سامي', 'بائع وأمين مستودع', 'المستودع', '2025-06-01', 360, 20, true, '0773333333', cc1),
    (co, 'EMP004', 'هبة ناصر', 'محاسبة', 'الإدارة', '2026-02-01', 500, 0, true, '0774444444', cc2);

  -- 7) فواتير الشراء (5) ومرتجع شراء — مرحّلة للمحاسبة والمخزون
  n := 0;
  for x in select * from jsonb_array_elements('[
      ["purchase","2026-10-02","credit","S0001","SUP-7781",[["I001",100,4.5],["I002",60,7],["I009",50,5]]],
      ["purchase","2026-10-05","credit","S0002","EST-2201",[["I003",300,0.6],["I010",400,0.4],["I007",150,1.2]]],
      ["purchase","2026-10-08","cash","S0003","AF-115",[["I006",120,2],["I011",80,2.8]]],
      ["purchase","2026-10-12","credit","S0004","RY-904",[["I008",100,3.5],["I012",500,0.3]]],
      ["purchase","2026-10-20","credit","S0001","SUP-7840",[["I004",150,2.5],["I005",40,8],["I001",50,4.8]]]]') loop
    n := n + 1;
    insert into public.invoices (company_id, fiscal_year_id, inv_type, inv_date, payment_type, party_id, reference, warehouse_id, cash_account_id, department_id, notes)
    values (co, fy, x ->> 0, (x ->> 1)::date, x ->> 2, (pid ->> (x ->> 3))::uuid, x ->> 4, w1,
            case when x ->> 2 = 'cash' then a_cash end, d_sh, 'فاتورة شراء تجريبية ' || n)
    returning id into inv;
    i := 0;
    for ln in select * from jsonb_array_elements(x -> 5) loop
      i := i + 1;
      insert into public.invoice_lines (invoice_id, line_no, item_id, description, qty, unit_price, discount, tax_rate)
      values (inv, i, (iid ->> (ln ->> 0))::uuid, (select name from public.items where id = (iid ->> (ln ->> 0))::uuid),
              (ln ->> 1)::numeric, (ln ->> 2)::numeric, 0, 16);
    end loop;
    perform public.post_invoice(inv);
    perform public.post_invoice_stock(inv);
  end loop;
  -- مرتجع شراء من الفاتورة الثانية
  insert into public.invoices (company_id, fiscal_year_id, inv_type, inv_date, payment_type, party_id, warehouse_id, department_id, original_invoice_id, notes)
  values (co, fy, 'purchase_return', '2026-10-22', 'credit', (pid ->> 'S0002')::uuid, w1, d_sh,
          (select id from public.invoices where company_id = co and reference = 'EST-2201'), 'ستيكرات فيها عيب طباعة')
  returning id into inv;
  insert into public.invoice_lines (invoice_id, line_no, item_id, description, qty, unit_price, discount, tax_rate)
  values (inv, 1, (iid ->> 'I010')::uuid, 'ستيكرات مجموعة 50 قطعة', 50, 0.4, 0, 16);
  perform public.post_invoice(inv); perform public.post_invoice_stock(inv);

  -- 8) تحويل بضاعة لفرع مكة مول
  insert into public.stock_docs (company_id, doc_type, doc_date, warehouse_id, to_warehouse_id, notes, department_id)
  values (co, 'transfer', '2026-10-15', w1, w2, 'تزويد فرع مكة مول', d_mm) returning id into sd;
  insert into public.stock_doc_lines (doc_id, line_no, item_id, qty) values
    (sd, 1, (iid ->> 'I001')::uuid, 20), (sd, 2, (iid ->> 'I002')::uuid, 10), (sd, 3, (iid ->> 'I009')::uuid, 10), (sd, 4, (iid ->> 'I006')::uuid, 20);
  perform public.post_stock_doc(sd);

  -- 9) فواتير البيع (10) ومرتجع بيع
  n := 0;
  for x in select * from jsonb_array_elements('[
      ["2026-10-06","cash","C0004",null,"W01",0,[["I001",3,9,0],["I003",5,1.5,0]]],
      ["2026-10-09","credit","C0001","R01","W01",0,[["I001",20,8.5,0],["I002",10,13,0],["I006",15,4.25,2]]],
      ["2026-10-11","credit","C0002","R01","W01",0,[["I007",60,2.75,0],["I010",100,1.1,0],["I003",50,1.35,0]]],
      ["2026-10-14","cash","C0004",null,"W02",1,[["I009",4,11,0],["I008",4,8,0],["I012",4,1,0]]],
      ["2026-10-17","credit","C0003","R02","W01",0,[["I009",20,10,0],["I011",15,6,0],["I002",8,13.5,0]]],
      ["2026-10-21","credit","C0005","R01","W01",0,[["I008",40,7.5,0],["I012",60,0.9,0],["I006",30,4.25,5]]],
      ["2026-10-25","cash","C0006",null,"W01",0,[["I005",2,16,0],["I004",3,6,0]]],
      ["2026-10-29","credit","C0001","R01","W01",0,[["I004",30,5.5,0],["I005",10,15,0],["I011",20,6,0]]],
      ["2026-11-03","credit","C0002","R01","W01",0,[["I010",120,1.1,0],["I007",40,2.75,0],["I003",80,1.35,0]]],
      ["2026-11-08","cash","C0004",null,"W02",1,[["I001",5,9,0],["I002",3,14,0],["I009",6,11,0],["I006",4,4.5,0]]]]') loop
    n := n + 1;
    insert into public.invoices (company_id, fiscal_year_id, inv_type, inv_date, due_date, payment_type, party_id, sales_rep_id, warehouse_id,
                                 cash_account_id, department_id, cost_center_id, notes)
    values (co, fy, 'sale', (x ->> 0)::date, case when x ->> 1 = 'credit' then (x ->> 0)::date + 30 end, x ->> 1,
            (pid ->> (x ->> 2))::uuid, (case when x ->> 3 = 'R01' then r1 when x ->> 3 = 'R02' then r2 end),
            case when x ->> 4 = 'W02' then w2 else w1 end, case when x ->> 1 = 'cash' then a_cash end,
            case when (x ->> 5) = '1' then d_mm else d_sh end, case when x ->> 2 = 'C0006' then cc2 else cc1 end, 'فاتورة بيع تجريبية ' || n)
    returning id into inv;
    i := 0;
    for ln in select * from jsonb_array_elements(x -> 6) loop
      i := i + 1;
      insert into public.invoice_lines (invoice_id, line_no, item_id, description, qty, unit_price, discount, tax_rate)
      values (inv, i, (iid ->> (ln ->> 0))::uuid, (select name from public.items where id = (iid ->> (ln ->> 0))::uuid),
              (ln ->> 1)::numeric, (ln ->> 2)::numeric, (ln ->> 3)::numeric, 16);
    end loop;
    perform public.post_invoice(inv);
    perform public.post_invoice_stock(inv);
  end loop;
  -- مرتجع بيع من فاتورة محل لمسة فن الأولى
  insert into public.invoices (company_id, fiscal_year_id, inv_type, inv_date, payment_type, party_id, sales_rep_id, warehouse_id, department_id, original_invoice_id, notes)
  values (co, fy, 'sale_return', '2026-11-10', 'credit', (pid ->> 'C0001')::uuid, r1, w1, d_sh,
          (select id from public.invoices where company_id = co and inv_type = 'sale' and party_id = (pid ->> 'C0001')::uuid order by inv_date limit 1),
          'مجسمين وصلوا مكسورين') returning id into inv;
  insert into public.invoice_lines (invoice_id, line_no, item_id, description, qty, unit_price, discount, tax_rate)
  values (inv, 1, (iid ->> 'I001')::uuid, 'مجسم شخصية كرتونية 15 سم', 2, 8.5, 0, 16);
  perform public.post_invoice(inv); perform public.post_invoice_stock(inv);

  -- 10) سندات القبض (وتوزيعها على الفواتير)
  for x in select * from jsonb_array_elements('[
      ["2026-10-20","C0001",300,"cash","دفعة من حساب فاتورة 9/10"],
      ["2026-10-30","C0002",400,"bank","حوالة على البنك العربي"],
      ["2026-11-05","C0003",250,"cash","دفعة نقدية"],
      ["2026-11-12","C0001",500,"bank","حوالة"]]') loop
    insert into public.journal_entries (company_id, fiscal_year_id, entry_type, entry_date, description, cash_account_id, department_id)
    values (co, fy, 'receipt', (x ->> 0)::date, x ->> 4, case when x ->> 3 = 'bank' then a_bank else a_cash end, d_sh) returning id into e;
    insert into public.journal_lines (entry_id, line_no, account_id, debit, credit, party_id, description) values
      (e, 1, case when x ->> 3 = 'bank' then a_bank else a_cash end, (x ->> 2)::numeric, 0, null, x ->> 4),
      (e, 2, a_ar, 0, (x ->> 2)::numeric, (pid ->> (x ->> 1))::uuid, x ->> 4);
    perform public.post_entry(e);
    perform public.auto_allocate(e, (pid ->> (x ->> 1))::uuid);
  end loop;

  -- 11) سندات الصرف: لمورد، ومصاريف (إيجار، كهرباء، إنترنت، إعلانات)
  for x in select * from jsonb_array_elements('[
      ["2026-10-01","E0001",1500,"bank","إيجار المعرض لشهر 10"],
      ["2026-10-15","E0003",35,"cash","فاتورة الإنترنت"],
      ["2026-10-18","E0004",120,"bank","حملة إعلانات الهالوين"],
      ["2026-10-25","S0001",1000,"bank","دفعة لمؤسسة النجمة"],
      ["2026-10-31","E0002",180,"cash","فاتورة الكهرباء والمياه"],
      ["2026-11-01","E0001",1500,"bank","إيجار المعرض لشهر 11"]]') loop
    insert into public.journal_entries (company_id, fiscal_year_id, entry_type, entry_date, description, cash_account_id, department_id)
    values (co, fy, 'payment', (x ->> 0)::date, x ->> 4, case when x ->> 3 = 'bank' then a_bank else a_cash end, d_sh) returning id into e;
    insert into public.journal_lines (entry_id, line_no, account_id, debit, credit, party_id, description, cost_center_id) values
      (e, 1, (select account_id from public.parties where id = (pid ->> (x ->> 1))::uuid), (x ->> 2)::numeric, 0, (pid ->> (x ->> 1))::uuid, x ->> 4,
       case when left(x ->> 1, 1) = 'E' then cc1 end),
      (e, 2, case when x ->> 3 = 'bank' then a_bank else a_cash end, 0, (x ->> 2)::numeric, null, x ->> 4, null);
    perform public.post_entry(e);
    if left(x ->> 1, 1) = 'S' then perform public.auto_allocate(e, (pid ->> (x ->> 1))::uuid); end if;
  end loop;

  -- 12) الشيكات: شيك وارد من شركة الفرح، وشيك صادر لشركة الشرق
  perform public.register_cheque(jsonb_build_object('company_id', co, 'direction', 'in', 'cheque_no', '100245', 'bank_name', 'بنك الإسكان',
          'issue_date', '2026-11-04', 'due_date', '2026-12-15', 'amount', 600, 'party_id', pid ->> 'C0005', 'drawer_name', 'شركة الفرح لتنظيم المناسبات',
          'notes', 'دفعة على حساب فاتورة 21/10'));
  perform public.register_cheque(jsonb_build_object('company_id', co, 'direction', 'out', 'cheque_no', '000731', 'bank_name', 'البنك العربي',
          'issue_date', '2026-11-06', 'due_date', '2026-12-01', 'amount', 800, 'party_id', pid ->> 'S0002', 'account_id', a_bank,
          'notes', 'دفعة لشركة الشرق'));

  -- 13) قيد يومية: مصاريف إعلانات مستحقة
  insert into public.journal_entries (company_id, fiscal_year_id, entry_type, entry_date, description)
  values (co, fy, 'journal', '2026-10-31', 'إثبات مصاريف تصوير إعلانات مستحقة لشهر 10') returning id into e;
  insert into public.journal_lines (entry_id, line_no, account_id, debit, credit, cost_center_id, description) values
    (e, 1, (select id from public.accounts where company_id = co and code = '5301'), 250, 0, cc2, 'تصوير منتجات للإعلانات'),
    (e, 2, (select id from public.accounts where company_id = co and code = '2107'), 0, 250, null, 'مستحقة للمصوّر');
  perform public.post_entry(e);

  -- 14) الرواتب: مسيّر شهر 10 مرحّل ومصروف من البنك
  insert into public.payroll_runs (company_id, period, run_date, notes) values (co, '2026-10', '2026-10-31', 'رواتب شهر تشرين الأول') returning id into run;
  perform public.payroll_fill(run);
  perform public.post_payroll(run);
  perform public.payroll_pay(run, jsonb_build_object('date', '2026-11-02', 'method', 'account', 'account_id', a_bank));

  -- 15) استهلاك الأصول لنهاية شهر 10
  perform public.post_depreciation(co, '2026-10-31');

  -- 16) سلفة لموظفة بالأقساط
  lid := public.loan_request(jsonb_build_object('company_id', co, 'employee_id', (select id from public.employees where company_id = co and code = 'EMP002'),
            'kind', 'advance', 'amount', 150, 'installments', 3, 'first_month', '2026-12', 'reason', 'ظرف عائلي'));
  perform public.loan_decide(lid, true, 'موافق');

  -- 17) طلب مبيعات مفتوح وطلب شراء
  insert into public.orders (company_id, order_type, order_date, valid_until, party_id, sales_rep_id, notes)
  values (co, 'sales_order', '2026-11-11', '2026-11-30', (pid ->> 'C0005')::uuid, r1, 'طلب هدايا حفل نهاية السنة') returning id into o;
  insert into public.order_lines (order_id, line_no, item_id, description, qty, unit_price, discount, tax_rate) values
    (o, 1, (iid ->> 'I008')::uuid, 'علبة هدايا مغلّفة جاهزة', 50, 7.5, 0, 16),
    (o, 2, (iid ->> 'I006')::uuid, 'كوب سيراميك مطبوع', 50, 4.25, 0, 16);
  insert into public.orders (company_id, order_type, order_date, party_id, notes)
  values (co, 'purchase_order', '2026-11-12', (pid ->> 'S0002')::uuid, 'طلبية موسم الأعياد') returning id into o;
  insert into public.order_lines (order_id, line_no, item_id, description, qty, unit_price, discount, tax_rate) values
    (o, 1, (iid ->> 'I009')::uuid, 'دبدوب محشو 30 سم', 100, 5, 0, 16),
    (o, 2, (iid ->> 'I002')::uuid, 'مجسم شخصية أنمي 20 سم', 50, 7, 0, 16);

  -- 18) عرض ترويجي
  insert into public.promotions (company_id, name, date_from, date_to, category_id, discount_pct, min_qty, notes)
  values (co, 'عرض نهاية السنة على الاكسسوارات', '2026-11-15', '2026-12-31',
          (select id from public.item_categories where company_id = co and code = '02'), 10, 1, 'خصم 10% على فئة الاكسسوارات');

  raise notice 'تمام: الشركة التجريبية %', co;
end $demo$;

reset role;
select set_config('request.jwt.claim.sub', '', false);
select c.code, c.name,
  (select count(*) from public.invoices where company_id = c.id) as invoices,
  (select count(*) from public.journal_entries where company_id = c.id) as entries,
  (select count(*) from public.journal_entries where company_id = c.id and status = 'posted') as posted
from public.companies c where c.name = 'عالم الشخصيات للاكسسوارات والهدايا';
