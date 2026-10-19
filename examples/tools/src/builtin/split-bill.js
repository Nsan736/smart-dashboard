// 割り勘(JavaScript 版)。1人あたりを、選んだ単位に切り上げる(足りなくならないように)。
var values = { total: '12800', people: 4, rounding: '100円単位' };

var SplitBill = {
  units: { '1円単位': 1, '10円単位': 10, '100円単位': 100, '500円単位': 500, '1000円単位': 1000 },
  // total 円を people 人で。{ perPerson, collected, surplus }。読めなければ null
  calculate: function (total, people, unit) {
    if (!(total >= 0) || !(people > 0) || !(unit > 0)) return null;
    total = Math.round(total);
    people = Math.round(people);
    var exact = Math.ceil(total / people);
    var per = Math.ceil(exact / unit) * unit;
    return { perPerson: per, collected: per * people, surplus: per * people - total };
  },
  // 幹事が端数を持つ: 他の人は単位で切り捨て、幹事が残りを払う
  organizer: function (total, people, unit) {
    if (!(total >= 0) || !(people > 1) || !(unit > 0)) return null;
    var others = Math.floor(total / people / unit) * unit;
    return { others: others, organizer: total - others * (people - 1) };
  }
};

function onInput(name, value) { values[name] = value; K.invalidate(); }
function onTouch(e) { K.touch(e); }
function frame() { K.frame(draw); }

function draw(w, h, th) {
  var pad = 12, cw = w - pad * 2, y = 12, x = pad + 14, iw = cw - 28;
  var total = K.parseNumber(values.total), people = Math.round(values.people), unit = SplitBill.units[values.rounding] || 1;
  K.card(pad, y, cw, 200, th);
  y += 14;
  var r = total === null ? null : SplitBill.calculate(total, people, unit);
  if (!r) { K.paragraph('合計の金額を入れてください', x, y, iw, 15, th.danger); return 230; }
  y += K.valueRow('1人あたり(' + people + '人)', K.group(r.perPerson) + '円', x, y, iw, th, { size: 32, color: th.accent }) + 12;
  y += K.valueRow('集まる合計', K.group(r.collected) + '円', x, y, iw, th, { size: 17 });
  y += K.valueRow('余り', K.group(r.surplus) + '円', x, y, iw, th, { size: 17 });
  var o = SplitBill.organizer(total, people, unit);
  if (o && unit > 1) {
    y += 8;
    ctx.fillStyle = th.line;
    ctx.fillRect(x, y, iw, 1);
    y += 8;
    y += K.valueRow('幹事が端数を持つと', '', x, y, iw, th, { size: 14 });
    y += K.valueRow('ほかの人', K.group(o.others) + '円', x, y, iw, th, { size: 17 });
    y += K.valueRow('幹事', K.group(o.organizer) + '円', x, y, iw, th, { size: 17 });
  }
  return y + 30;
}
