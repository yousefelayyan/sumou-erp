// =====================================================================
//  السمو ERP — ملف العميل/المورد الإحصائي (route party-profile?id=…)
//  كل أرقام الطرف بشاشة وحدة من party_profile(company, party): رصيد، مفتوح ومتأخر، 12 شهر، أكثر الأصناف، شيكات…
// =====================================================================
import { S, sb, esc, fmtDate, fmtNum, num, toast, arError, can } from './core.js';
import { loadParties, partyLabel, partyDatalist, resolveParty } from './parties.js';
import { printDoc } from './print.js';

const qp = () => new URLSearchParams(location.hash.split('?')[1] || '');
const card = (label, value, sub = '', color = '') => `<div class="card" style="padding:12px;text-align:center">
  <div class="muted" style="font-size:12px">${label}</div><div style="font-size:22px;font-weight:800;${color ? 'color:' + color : ''}">${value}</div>
  ${sub ? `<div class="muted" style="font-size:11px">${sub}</div>` : ''}</div>`;
const days = (d) => d ? Math.round((Date.now() - new Date(d)) / 864e5) : null;

async function viewProfile(v) {
  if (!S.company) return void (v.innerHTML = '<div class="notice info">اختار شركة من فوق أول.</div>');
  const parties = await loadParties();
  const id = qp().get('id');
  const p0 = parties.find(x => x.id === id);
  v.innerHTML = `<div class="page-head"><h2>📊 ملف العميل / المورد</h2><div class="spacer"></div>
      <input class="search" list="pp-list" id="pp" placeholder="اختار عميل أو مورد…" value="${esc(partyLabel(p0))}" style="min-width:280px">${partyDatalist(parties, 'pp-list')}
      ${id ? '<button class="btn" id="pr">🖨️ طباعة</button>' : ''}</div><div id="pp-body">${id ? '<div class="muted">بيحمّل…</div>' : '<div class="notice info">اختار عميل أو مورد من فوق.</div>'}</div>`;
  v.querySelector('#pp').onchange = (e) => { const p = resolveParty(parties, e.target.value); if (p) location.hash = `#/party-profile?id=${p.id}`; };
  if (!id) return;
  const { data: j, error } = await sb.rpc('party_profile', { p_company: S.company.id, p_party: id });
  if (error) return void (v.querySelector('#pp-body').innerHTML = `<div class="notice">${esc(arError(error))}</div>`);
  const sup = j.party.type === 'supplier', word = sup ? 'المشتريات' : 'المبيعات';
  const bal = num(j.balance) * (sup ? -1 : 1);
  const growth = num(j.last_year_total) ? Math.round((num(j.year_total) - num(j.last_year_total)) / Math.abs(num(j.last_year_total)) * 100) : null;
  const lastInvDays = days(j.last_invoice?.date);
  const status = !j.invoice_count ? ['لسا ما اشترى', ''] : lastInvDays <= 30 ? ['نشط', 'ok'] : lastInvDays <= 60 ? ['متراجع', 'warn'] : ['متوقف', 'bad'];
  const mx = Math.max(1, ...j.monthly.map(m => Math.max(Math.abs(num(m.v)), Math.abs(num(m.p)))));
  const limit = num(j.party.credit_limit), used = limit ? Math.min(100, Math.round(Math.max(bal, 0) / limit * 100)) : 0;
  v.querySelector('#pp-body').innerHTML = `
    <div class="card" style="display:flex;gap:14px;align-items:center;flex-wrap:wrap;margin-bottom:10px">
      <div style="font-size:40px">${sup ? '🏭' : '🧑‍💼'}</div>
      <div style="flex:1;min-width:200px"><h3 style="margin:0">${esc(j.party.name)} <span class="badge ${status[1]}">${sup && j.invoice_count ? 'مورد' : status[0]}</span>${j.party.is_active ? '' : ' <span class="badge bad">موقوف</span>'}</h3>
        <div class="muted" style="font-size:13px">${esc(j.party.code)}${j.party.phone ? ' · ' + esc(j.party.phone) : ''} · أول فاتورة ${j.first_invoice ? fmtDate(j.first_invoice) : '—'}</div></div>
      <a class="btn sm" href="#/rep-party?party=${id}">📄 كشف الحساب</a>
      ${can(sup ? 'purchase_invoices' : 'sales_invoices', 'view') ? `<a class="btn sm" href="#/${sup ? 'purchases?t=purchase' : 'sales?t=sale'}">🧾 الفواتير</a>` : ''}</div>
    <div class="grid cols-4" style="gap:10px">
      ${j.balance == null ? '' : card('الرصيد الحالي', fmtNum(Math.abs(bal)), bal > 0 ? (sup ? 'إلنا عليه' : 'علينا تحصيله') : bal < 0 ? (sup ? 'مستحق إله' : 'رصيد دائن إله') : 'مسدّد', bal > 0 && !sup ? 'var(--bad)' : '')}
      ${limit && !sup ? card('سقف الائتمان', fmtNum(limit), `مستعمل ${used}%`, used >= 100 ? 'var(--bad)' : '') : ''}
      ${j.open_amount != null ? card('فواتير مفتوحة', fmtNum(j.open_amount), `${j.open_count || 0} فاتورة${j.oldest_open ? ' · أقدمها ' + days(j.oldest_open) + ' يوم' : ''}`) : ''}
      ${j.overdue_amount != null ? card('متأخر السداد', fmtNum(j.overdue_amount), num(j.overdue_30) ? `منها ${fmtNum(j.overdue_30)} فوق 30 يوم` : '', num(j.overdue_amount) ? 'var(--bad)' : '') : ''}
      ${card(`${word} هالسنة`, fmtNum(j.year_total), growth == null ? '' : `${growth >= 0 ? '▲' : '▼'} ${Math.abs(growth)}% عن السنة الماضية (${fmtNum(j.last_year_total)})`, growth == null ? '' : growth >= 0 ? 'var(--ok)' : 'var(--bad)')}
      ${card('متوسط الفاتورة', j.avg_invoice ? fmtNum(j.avg_invoice) : '—', `${j.invoice_count} فاتورة · كل الوقت ${fmtNum(j.all_total)}`)}
      ${card('آخر فاتورة', j.last_invoice ? fmtDate(j.last_invoice.date) : '—', j.last_invoice ? `رقم ${esc(j.last_invoice.no)} · ${fmtNum(j.last_invoice.total)} · قبل ${lastInvDays} يوم` : '')}
      ${card(sup ? 'آخر دفعة إله' : 'آخر دفعة منه', j.last_payment ? fmtNum(j.last_payment.amount) : '—', j.last_payment ? `${fmtDate(j.last_payment.date)} · قبل ${days(j.last_payment.date)} يوم` : '')}
      ${card(sup ? 'مدفوع هالسنة' : 'محصّل هالسنة', fmtNum(j.payments_year), j.avg_pay_days != null ? `متوسط السداد ${j.avg_pay_days} يوم من الفاتورة` : '')}
      ${card('المرتجعات', fmtNum(j.returns_total), num(j.all_total) + num(j.returns_total) ? `${Math.round(num(j.returns_total) / (num(j.all_total) + num(j.returns_total)) * 100)}% من ${word}` : '')}
      ${card('شيكات بالمحفظة', fmtNum(j.cheques.portfolio), `${j.cheques.portfolio_count} شيك${j.cheques.returned_count ? ` · راجع ${j.cheques.returned_count} (${fmtNum(j.cheques.returned_amount)})` : ''}`, j.cheques.returned_count ? 'var(--bad)' : '')}
      ${card('نشاط', `${j.open_orders} طلب مفتوح`, `${j.visits_90} زيارة بآخر 90 يوم · ${j.messages} رسالة`)}
    </div>
    <div class="card" style="margin-top:10px"><h4 style="margin:0 0 8px">${word} و${sup ? 'الدفعات' : 'التحصيل'} — آخر 12 شهر</h4>
      <div style="display:flex;gap:6px;align-items:flex-end;height:170px;direction:ltr">
        ${j.monthly.map(m => `<div style="flex:1;display:flex;flex-direction:column;align-items:center;gap:2px" title="${m.m}: ${word} ${fmtNum(m.v)} — ${sup ? 'دفعات' : 'تحصيل'} ${fmtNum(m.p)}">
          <div style="display:flex;gap:2px;align-items:flex-end;height:140px;width:100%;justify-content:center">
            <div style="width:42%;background:var(--brand);border-radius:3px 3px 0 0;height:${Math.max(0, num(m.v)) / mx * 100}%"></div>
            <div style="width:42%;background:var(--ok);opacity:.7;border-radius:3px 3px 0 0;height:${Math.max(0, num(m.p)) / mx * 100}%"></div></div>
          <div class="muted" style="font-size:10px">${m.m.slice(5)}/${m.m.slice(2, 4)}</div></div>`).join('')}</div>
      <div class="muted" style="font-size:12px;margin-top:4px"><span style="display:inline-block;width:10px;height:10px;background:var(--brand)"></span> ${word} (صافي بعد المرتجعات، قبل الضريبة) &nbsp; <span style="display:inline-block;width:10px;height:10px;background:var(--ok);opacity:.7"></span> ${sup ? 'الدفعات' : 'التحصيل'}</div></div>
    <div class="card table-wrap" style="margin-top:10px"><h4 style="margin:0 0 8px">أكثر 10 أصناف</h4><table class="t"><thead><tr><th>الصنف</th><th style="text-align:left">الكمية</th><th style="text-align:left">القيمة</th><th>آخر مرة</th></tr></thead><tbody>
      ${(j.top_items || []).map(x => `<tr><td>${esc(x.code)} — ${esc(x.name)}</td><td class="n">${fmtNum(x.q)}</td><td class="n">${fmtNum(x.v)}</td><td>${fmtDate(x.last)}</td></tr>`).join('') || '<tr><td colspan="4" class="empty">ما في أصناف</td></tr>'}</tbody></table></div>`;
  v.querySelector('#pr')?.addEventListener('click', () => printDoc(`ملف ${sup ? 'المورد' : 'العميل'}: ${j.party.code} — ${j.party.name}`, v.querySelector('#pp-body').innerHTML.replace(/class="t"/g, 'class="pt"'), { landscape: true }));
}

export const PROFILE_ROUTES = { 'party-profile': viewProfile };
