import { useState, useMemo } from "react";

const FORMS = [
  { id: "arrow", name: "Стрела", area: 1, dmgMult: 1.5, manaMult: 1.0, range: 12, desc: "Далеко, точно, одна цель. Снайперский снаряд." },
  { id: "shell", name: "Снаряд", area: 3, dmgMult: 1.0, manaMult: 1.2, range: 8, desc: "Средняя дальность, взрывается при попадании." },
  { id: "shot", name: "Дробь", area: 6, dmgMult: 0.4, manaMult: 0.8, range: 6, desc: "Россыпь осколков. Большая площадь, слабый эффект." },
];

const ELEMENTS = [
  { id: "fire", name: "Огонь", baseMult: 1.0, color: "#e74c3c" },
  { id: "water", name: "Вода", baseMult: 1.0, color: "#3498db" },
  { id: "earth", name: "Земля", baseMult: 1.0, color: "#8B7355" },
];

const INTENTS = [
  { id: "destroy", name: "Уничтожить", baseDmg: 200, baseMana: 80, icon: "💥" },
  { id: "protect", name: "Защитить", baseDmg: 0, baseMana: 50, icon: "🛡️" },
  { id: "see", name: "Увидеть", baseDmg: 0, baseMana: 35, icon: "👁️" },
];

const TILES = [
  { id: "forest", name: "Лес" },
  { id: "water", name: "Вода" },
  { id: "stone", name: "Камень" },
  { id: "village", name: "Деревня" },
  { id: "ice", name: "Лёд" },
  { id: "plain", name: "Равнина" },
];

const TILE_MULTS = {
  fire:  { forest: 1.8, water: 0.3, stone: 1.0, village: 1.8, ice: 0.5, plain: 1.0 },
  water: { forest: 1.0, water: 1.0, stone: 0.3, village: 1.8, ice: 1.8, plain: 1.0 },
  earth: { forest: 0.5, water: 1.8, stone: 1.8, village: 1.0, ice: 0.5, plain: 1.0 },
};

const TILE_EFFECTS = {
  fire:  { forest: "Пожар (+2 тайла)", water: "Пар (туман)", stone: "Плавление", village: "Разрушение", ice: "Таяние → вода", plain: "Выжигание" },
  water: { forest: "Рост (+ресурсы)", water: "Наводнение", stone: "Эрозия (путь)", village: "Урожай (+лояльн.)", ice: "Расширение льда", plain: "Болото (замедл.)" },
  earth: { forest: "Корни (стена)", water: "Болото (замедл.)", stone: "Усиление (+деф)", village: "Укрепление", ice: "Завалка", plain: "Каменная стена" },
};

// All 27 spell descriptions
const SPELL_DESC = {
  // ОГОНЬ + УНИЧТОЖИТЬ
  "arrow_fire_destroy": {
    name: "Огненная стрела",
    desc: "Точечный удар, высокий урон. При попадании в лес — поджигает, огонь ползёт на соседние тайлы. Промахнулся мимо вражеского замка и попал в свой лес — пожар пойдёт к тебе.",
    tactical: "Снайперский удар по замку или постройке",
  },
  "shell_fire_destroy": {
    name: "Огненная бомба",
    desc: "Взрывается при попадании, поджигает зону. Основной боевой снаряд. Деревню уничтожает полностью. На воде создаёт пар и туман, урон слабый.",
    tactical: "Главный рабочий снаряд для артдуэли",
  },
  "shot_fire_destroy": {
    name: "Огненный дождь",
    desc: "Россыпь мелких огненных снарядов по площади. Каждый слабый, но на лесу — всё загорится. Плох против каменных укреплений — осколки не пробивают.",
    tactical: "Выжигание региона перед наступлением",
  },
  // ОГОНЬ + ЗАЩИТИТЬ
  "arrow_fire_protect": {
    name: "Огненный столб",
    desc: "Создаёт горящую точку-преграду. Блокирует один проход на несколько ходов. Миньоны врага не пройдут, но и твои тоже.",
    tactical: "Закупорка узких мест на карте",
  },
  "shell_fire_protect": {
    name: "Огненная стена",
    desc: "Полоса огня. Временный барьер. Бронированные миньоны пройдут с потерями, голые сгорят. Фильтр а не стена.",
    tactical: "Замедление и фильтрация вражеской армии",
  },
  "shot_fire_protect": {
    name: "Огненное поле",
    desc: "Россыпь мелких очагов. Вся зона — минное поле. Враг проходит но несёт потери на каждом тайле. Долго горит, но слабо.",
    tactical: "Зона контроля, изматывание армии",
  },
  // ОГОНЬ + УВИДЕТЬ
  "arrow_fire_see": {
    name: "Сигнальная ракета",
    desc: "Летит далеко, освещает точку и радиус вокруг. Стреляешь наугад — увидел замок или нет. Дёшево и быстро.",
    tactical: "Базовая точечная разведка",
  },
  "shell_fire_see": {
    name: "Осветительная бомба",
    desc: "Взрыв освещает среднюю зону. Если попал в лес — пожар освещает дальше при распространении. Побочный бонус: поджёг и увидел.",
    tactical: "Разведка с побочным уроном",
  },
  "shot_fire_see": {
    name: "Фейерверк",
    desc: "Россыпь искр по большой площади. Раскрывает огромную зону но ненадолго. Враг тоже видит — понимает что его нашли. Идеально перед массированным обстрелом.",
    tactical: "Раскрытие площади перед ударом",
  },
  // ВОДА + УНИЧТОЖИТЬ
  "arrow_water_destroy": {
    name: "Ледяная стрела",
    desc: "Точечный удар, пробивает и замораживает. На воде — замораживает тайл, создаёт лёд. Деревню парализует на несколько ходов, заморозив ресурсы.",
    tactical: "Точечная заморозка цели",
  },
  "shell_water_destroy": {
    name: "Водяная бомба",
    desc: "Затапливает зону. На равнине создаёт болото. Деревню разрушает наводнением. Против каменного замка слабо — вода стекает. Но если попал в подвал — вывел из строя нижние этажи.",
    tactical: "Затопление зоны, создание болот",
  },
  "shot_water_destroy": {
    name: "Ледяной град",
    desc: "Россыпь ледяных осколков. Каждый слабый но замедляет. Зона покрывается льдом. Миньоны скользят, теряют строй. Не убивает — парализует армию.",
    tactical: "Массовое замедление вражеской армии",
  },
  // ВОДА + ЗАЩИТИТЬ
  "arrow_water_protect": {
    name: "Ледяной шип",
    desc: "Ледяная глыба в точке. Физическое препятствие, враг обходит или ломает. Тает со временем. Дёшево — хорош для закрытия одного прохода.",
    tactical: "Временная точечная блокировка",
  },
  "shell_water_protect": {
    name: "Ледяная стена",
    desc: "Замораживает зону, стена льда. Прочнее огненной, дольше стоит, не наносит урон. На водном тайле — замораживает водоём, создаёт мост. И стена и путь.",
    tactical: "Прочный барьер или создание моста",
  },
  "shot_water_protect": {
    name: "Ледяной каток",
    desc: "Площадь покрывается льдом. Не стена а поверхность. Враг скользит и движется непредсказуемо. Свои тоже скользят — обоюдоострое.",
    tactical: "Хаотизация передвижения в зоне",
  },
  // ВОДА + УВИДЕТЬ
  "arrow_water_see": {
    name: "Водяной зонд",
    desc: "Попадает в точку и «растекается» вдоль водных тайлов. На реке — видишь всё вдоль неё. На суше — видишь мало. Мощный если знаешь где вода.",
    tactical: "Разведка по водным путям",
  },
  "shell_water_see": {
    name: "Дождевое облако",
    desc: "Зона дождя, видишь всё что мокнет. После рассеивания остаются лужи — по ним видны следы юнитов. Остаточная разведка.",
    tactical: "Разведка со следами",
  },
  "shot_water_see": {
    name: "Туманный залп",
    desc: "Создаёт туман. Ты видишь контуры врага в тумане, но враг получает укрытие. Узнал где он — но теперь ему легче прятаться. Разведка с ценой.",
    tactical: "Обнаружение позиций ценой укрытия врагу",
  },
  // ЗЕМЛЯ + УНИЧТОЖИТЬ
  "arrow_earth_destroy": {
    name: "Каменный болт",
    desc: "Чистая кинетика. Максимальный урон по бронированным целям. Пробивает стены замка. Не поджигает, не затапливает — просто дырка.",
    tactical: "Лучший снаряд против укреплённого замка",
  },
  "shell_earth_destroy": {
    name: "Землетрясение",
    desc: "Проламывает землю, создаёт яму. Всё что было — падает вниз. Яма остаётся как непроходимый тайл. Уничтожил и создал препятствие одновременно.",
    tactical: "Разрушение + создание преграды",
  },
  "shot_earth_destroy": {
    name: "Камнепад",
    desc: "Россыпь булыжников по площади. Каждый бьёт слабо но остаётся лежать. Ровная местность превращается в завал. Не убил но перегородил обломками.",
    tactical: "Массовое замедление через завалы",
  },
  // ЗЕМЛЯ + ЗАЩИТИТЬ
  "arrow_earth_protect": {
    name: "Каменный столб",
    desc: "Каменная колонна мгновенно вырастает. Прочнее льда, не тает. Постоянное препятствие. Можно строить стены по столбу за раз.",
    tactical: "Постоянная точечная блокировка",
  },
  "shell_earth_protect": {
    name: "Каменная стена",
    desc: "Поднимает стену из земли. Самый прочный барьер в игре. Не горит, не тает. Враг ломает или обходит. Ты тоже не пройдёшь — осторожно с размещением.",
    tactical: "Самая мощная защита, необратимая",
  },
  "shot_earth_protect": {
    name: "Каменная насыпь",
    desc: "Россыпь камней создаёт возвышенность. Не стена а холм. Миньоны на насыпи получают бонус к обзору и обороне. Тактическая позиция.",
    tactical: "Создание укреплённой позиции",
  },
  // ЗЕМЛЯ + УВИДЕТЬ
  "arrow_earth_see": {
    name: "Сейсмозонд",
    desc: "Вонзается в землю, «слушает» вибрации. Показывает движение юнитов, не рельеф. Работает через стены. Не видишь что — но видишь что кто-то идёт.",
    tactical: "Обнаружение движения через препятствия",
  },
  "shell_earth_see": {
    name: "Тектонический удар",
    desc: "Сотрясает зону. Раскрывает скрытые структуры — ловушки, подземные ходы, замаскированные укрепления. Видишь инфраструктуру, не юнитов.",
    tactical: "Разведка скрытых построек и ловушек",
  },
  "shot_earth_see": {
    name: "Каменные маячки",
    desc: "Россыпь камней-датчиков по площади. Любой юнит наступивший на маячок — обнаружен. Пассивная долговременная разведка. Минное поле, только вместо взрыва — пинг.",
    tactical: "Долговременная пассивная система обнаружения",
  },
};

const SYNERGIES = {
  "arrow_fire_destroy": { name: "Драконье Копьё", bonus: 1.2 },
  "shell_water_destroy": { name: "Потоп", bonus: 1.2 },
  "shell_earth_protect": { name: "Крепость", bonus: 1.2 },
  "shot_fire_destroy": { name: "Армагеддон", bonus: 1.2 },
  "arrow_earth_destroy": { name: "Пробойник", bonus: 1.2 },
  "shell_fire_destroy": { name: "Напалм", bonus: 1.2 },
  "shot_water_destroy": { name: "Ледниковый Период", bonus: 1.2 },
  "shot_earth_see": { name: "Сеть Стража", bonus: 1.2 },
  "shell_water_protect": { name: "Ледяная Крепость", bonus: 1.2 },
};

function Pill({ children, active, color, onClick }) {
  return (
    <button onClick={onClick} style={{
      padding: "10px 18px", borderRadius: 10, cursor: "pointer",
      background: active ? `${color}18` : "rgba(255,255,255,0.03)",
      border: active ? `2px solid ${color}` : "2px solid rgba(255,255,255,0.07)",
      color: active ? color : "rgba(255,255,255,0.4)",
      fontFamily: "'Cinzel', serif", fontSize: 14, fontWeight: active ? 700 : 400,
      transition: "all 0.25s ease",
      boxShadow: active ? `0 0 16px ${color}20` : "none",
    }}>
      {children}
    </button>
  );
}

function Bar({ label, value, max, color, suffix = "" }) {
  const pct = max > 0 ? Math.min((value / max) * 100, 100) : 0;
  return (
    <div style={{ marginBottom: 12 }}>
      <div style={{ display: "flex", justifyContent: "space-between", marginBottom: 4 }}>
        <span style={{ fontSize: 11, color: "rgba(255,255,255,0.45)", fontFamily: "'Cormorant Garamond', serif", textTransform: "uppercase", letterSpacing: "1px" }}>{label}</span>
        <span style={{ fontSize: 15, fontFamily: "'Cinzel', serif", fontWeight: 700, color }}>{value}{suffix}</span>
      </div>
      <div style={{ height: 5, background: "rgba(255,255,255,0.05)", borderRadius: 3 }}>
        <div style={{ height: "100%", width: `${pct}%`, background: color, borderRadius: 3, transition: "width 0.4s ease" }} />
      </div>
    </div>
  );
}

export default function BalanceCalc() {
  const [formId, setFormId] = useState("arrow");
  const [elemId, setElemId] = useState("fire");
  const [intentId, setIntentId] = useState("destroy");
  const [tileId, setTileId] = useState("plain");
  const [showAll, setShowAll] = useState(false);
  const [sortBy, setSortBy] = useState("dmg");

  const calc = useMemo(() => {
    const form = FORMS.find(f => f.id === formId);
    const elem = ELEMENTS.find(e => e.id === elemId);
    const intent = INTENTS.find(i => i.id === intentId);
    const key = `${formId}_${elemId}_${intentId}`;
    const spell = SPELL_DESC[key] || {};
    const synergy = SYNERGIES[key] || null;
    const synMult = synergy ? synergy.bonus : 1.0;
    const tileMult = TILE_MULTS[elemId][tileId];
    const tileEffect = TILE_EFFECTS[elemId][tileId];

    const totalDmg = Math.round(intent.baseDmg * form.dmgMult * elem.baseMult * tileMult * synMult);
    const totalMana = Math.round(intent.baseMana * form.manaMult);
    const dpm = totalMana > 0 ? Math.round((totalDmg / totalMana) * 10) / 10 : 0;

    return { form, elem, intent, spell, synergy, synMult, tileMult, tileEffect, totalDmg, totalMana, dpm, key };
  }, [formId, elemId, intentId, tileId]);

  const allCombos = useMemo(() => {
    const out = [];
    for (const f of FORMS) for (const e of ELEMENTS) for (const i of INTENTS) {
      const key = `${f.id}_${e.id}_${i.id}`;
      const sp = SPELL_DESC[key] || {};
      const syn = SYNERGIES[key] || null;
      const synM = syn ? syn.bonus : 1.0;
      const dmg = Math.round(i.baseDmg * f.dmgMult * e.baseMult * synM);
      const mana = Math.round(i.baseMana * f.manaMult);
      const dpm = mana > 0 ? Math.round((dmg / mana) * 10) / 10 : 0;
      out.push({ formId: f.id, elemId: e.id, intentId: i.id, form: f.name, elem: e.name, intent: i.name,
        name: sp.name || "—", tactical: sp.tactical || "", dmg, mana, dpm, synergy: syn?.name || "", elemColor: e.color, key });
    }
    return out;
  }, []);

  const sorted = useMemo(() => [...allCombos].sort((a, b) =>
    sortBy === "dmg" ? b.dmg - a.dmg : sortBy === "mana" ? a.mana - b.mana : sortBy === "name" ? a.name.localeCompare(b.name) : b.dpm - a.dpm
  ), [allCombos, sortBy]);

  const maxDmg = 500;
  const maxMana = 120;

  return (
    <div style={{ minHeight: "100vh", background: "#08080f", color: "white", fontFamily: "'Cormorant Garamond', serif" }}>
      <style>{`
        @import url('https://fonts.googleapis.com/css2?family=Cinzel:wght@400;700;900&family=Cormorant+Garamond:ital,wght@0,400;0,600;0,700;1,400&display=swap');
        * { box-sizing: border-box; margin: 0; padding: 0; }
        ::-webkit-scrollbar { width: 4px; }
        ::-webkit-scrollbar-thumb { background: rgba(255,255,255,0.12); border-radius: 4px; }
        button:hover { filter: brightness(1.12); }
      `}</style>

      <div style={{ maxWidth: 960, margin: "0 auto", padding: "36px 20px" }}>
        <h1 style={{ fontFamily: "'Cinzel', serif", fontSize: 24, fontWeight: 900, letterSpacing: "3px", textAlign: "center", textTransform: "uppercase", color: "rgba(255,255,255,0.8)", marginBottom: 4 }}>
          Баланс Заклинаний
        </h1>
        <p style={{ textAlign: "center", fontSize: 13, color: "rgba(255,255,255,0.25)", letterSpacing: "2px", marginBottom: 36 }}>
          3 формы · 3 стихии · 3 намерения · 27 снарядов
        </p>

        {/* Selectors */}
        <div style={{ display: "grid", gap: 20, marginBottom: 28, background: "rgba(255,255,255,0.015)", border: "1px solid rgba(255,255,255,0.05)", borderRadius: 14, padding: 24 }}>
          {[
            { label: "Форма", sub: "находишь на карте", items: FORMS, sel: formId, set: setFormId, color: "#c0392b" },
            { label: "Стихия", sub: "всегда доступна", items: ELEMENTS, sel: elemId, set: setElemId },
            { label: "Намерение", sub: "тактический выбор", items: INTENTS, sel: intentId, set: setIntentId, color: "#f39c12" },
          ].map(axis => (
            <div key={axis.label}>
              <div style={{ display: "flex", alignItems: "baseline", gap: 10, marginBottom: 10 }}>
                <span style={{ fontSize: 11, fontFamily: "'Cinzel', serif", color: "rgba(255,255,255,0.35)", textTransform: "uppercase", letterSpacing: "2px" }}>{axis.label}</span>
                <span style={{ fontSize: 11, color: "rgba(255,255,255,0.15)", letterSpacing: "1px" }}>{axis.sub}</span>
              </div>
              <div style={{ display: "flex", gap: 8, flexWrap: "wrap" }}>
                {axis.items.map(item => (
                  <Pill key={item.id} active={axis.sel === item.id} color={item.color || axis.color || "#888"} onClick={() => axis.set(item.id)}>
                    {item.icon ? `${item.icon} ` : ""}{item.name}
                  </Pill>
                ))}
              </div>
            </div>
          ))}
        </div>

        {/* Spell Card */}
        <div style={{ background: "rgba(0,0,0,0.35)", border: "1px solid rgba(255,255,255,0.07)", borderRadius: 16, padding: 28, marginBottom: 24, position: "relative", overflow: "hidden" }}>
          <div style={{ position: "absolute", top: 0, left: 0, right: 0, height: 120, background: `linear-gradient(180deg, ${calc.elem.color}10, transparent)`, pointerEvents: "none" }} />

          <div style={{ position: "relative", zIndex: 1 }}>
            {/* Synergy badge */}
            {calc.synergy && (
              <div style={{ background: `${calc.elem.color}18`, border: `1px solid ${calc.elem.color}44`, borderRadius: 10, padding: "10px 16px", marginBottom: 18, display: "flex", alignItems: "center", gap: 10 }}>
                <span style={{ fontSize: 18 }}>⚡</span>
                <span style={{ fontFamily: "'Cinzel', serif", fontSize: 17, fontWeight: 700, color: calc.elem.color }}>{calc.synergy.name}</span>
                <span style={{ fontSize: 12, color: "rgba(255,255,255,0.45)" }}>+20%</span>
              </div>
            )}

            {/* Spell name */}
            <div style={{ fontFamily: "'Cinzel', serif", fontSize: 22, fontWeight: 700, color: "rgba(255,255,255,0.9)", marginBottom: 6 }}>
              {calc.spell.name || "—"}
            </div>
            <div style={{ fontSize: 13, color: "rgba(255,255,255,0.3)", marginBottom: 16, letterSpacing: "1px" }}>
              {calc.form.name} · {calc.elem.name} · {calc.intent.name}
            </div>

            {/* Description */}
            <div style={{ fontSize: 15, color: "rgba(255,255,255,0.65)", lineHeight: 1.7, marginBottom: 12, maxWidth: 600 }}>
              {calc.spell.desc || ""}
            </div>
            <div style={{ fontSize: 13, color: calc.elem.color, fontWeight: 600, marginBottom: 24, fontFamily: "'Cinzel', serif", letterSpacing: "0.5px" }}>
              → {calc.spell.tactical || ""}
            </div>

            {/* Stats */}
            <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 28 }}>
              <div>
                <Bar label="Урон" value={calc.totalDmg} max={maxDmg} color={calc.elem.color} />
                <Bar label="Мана" value={calc.totalMana} max={maxMana} color="#3498db" />
                <Bar label="Урон за ману" value={calc.dpm} max={8} color="#2ecc71" />
                <Bar label="Площадь (тайлы)" value={calc.form.area} max={6} color="#f39c12" />
                <Bar label="Дальность" value={calc.form.range} max={12} color="#9b59b6" />

                <div style={{ fontSize: 11, color: "rgba(255,255,255,0.2)", marginTop: 8, lineHeight: 1.6 }}>
                  {calc.intent.baseDmg} × {calc.form.dmgMult} × {calc.elem.baseMult} × {calc.tileMult}{calc.synergy ? " × 1.2" : ""} = {calc.totalDmg}
                </div>
              </div>

              {/* Tile selector & effects */}
              <div>
                <div style={{ fontSize: 11, color: "rgba(255,255,255,0.3)", textTransform: "uppercase", letterSpacing: "1.5px", marginBottom: 10, fontFamily: "'Cinzel', serif" }}>Тайл цели</div>
                <div style={{ display: "grid", gridTemplateColumns: "repeat(3, 1fr)", gap: 5, marginBottom: 16 }}>
                  {TILES.map(t => {
                    const m = TILE_MULTS[elemId][t.id];
                    const d = Math.round(calc.intent.baseDmg * calc.form.dmgMult * calc.elem.baseMult * m * calc.synMult);
                    const active = t.id === tileId;
                    const c = m >= 1.5 ? "#27ae60" : m <= 0.5 ? "#e74c3c" : "rgba(255,255,255,0.35)";
                    return (
                      <button key={t.id} onClick={() => setTileId(t.id)} style={{
                        background: active ? `${calc.elem.color}12` : "rgba(255,255,255,0.02)",
                        border: active ? `1px solid ${calc.elem.color}40` : "1px solid rgba(255,255,255,0.04)",
                        borderRadius: 8, padding: "8px 4px", textAlign: "center", cursor: "pointer",
                      }}>
                        <div style={{ fontSize: 10, color: "rgba(255,255,255,0.35)" }}>{t.name}</div>
                        <div style={{ fontSize: 15, fontFamily: "'Cinzel', serif", fontWeight: 700, color: c }}>{d > 0 ? d : "—"}</div>
                        <div style={{ fontSize: 10, color: c }}>×{m}</div>
                      </button>
                    );
                  })}
                </div>

                <div style={{ fontSize: 11, color: "rgba(255,255,255,0.3)", textTransform: "uppercase", letterSpacing: "1.5px", marginBottom: 6, fontFamily: "'Cinzel', serif" }}>Эффект на тайле</div>
                <div style={{ background: `${calc.elem.color}12`, border: `1px solid ${calc.elem.color}22`, borderRadius: 8, padding: "10px 14px", fontSize: 14, color: calc.elem.color, fontWeight: 600 }}>
                  {calc.tileEffect}
                </div>
              </div>
            </div>
          </div>
        </div>

        {/* All 27 combos */}
        <button onClick={() => setShowAll(!showAll)} style={{
          width: "100%", padding: "14px", borderRadius: 10, cursor: "pointer", marginBottom: 16,
          background: "rgba(255,255,255,0.03)", border: "1px solid rgba(255,255,255,0.07)",
          color: "rgba(255,255,255,0.4)", fontFamily: "'Cinzel', serif", fontSize: 13, letterSpacing: "1px",
        }}>
          {showAll ? "Скрыть" : "Показать"} все 27 комбинаций
        </button>

        {showAll && (
          <div style={{ background: "rgba(0,0,0,0.3)", border: "1px solid rgba(255,255,255,0.05)", borderRadius: 14, overflow: "hidden" }}>
            <div style={{ display: "flex", gap: 8, padding: "12px 16px", borderBottom: "1px solid rgba(255,255,255,0.05)", alignItems: "center" }}>
              <span style={{ fontSize: 11, color: "rgba(255,255,255,0.3)" }}>Сортировка:</span>
              {[["name", "Имя"], ["dmg", "Урон ↓"], ["mana", "Мана ↑"], ["dpm", "У/М ↓"]].map(([k, l]) => (
                <button key={k} onClick={() => setSortBy(k)} style={{
                  padding: "4px 12px", borderRadius: 6, fontSize: 11, cursor: "pointer",
                  background: sortBy === k ? "rgba(255,255,255,0.08)" : "transparent",
                  border: sortBy === k ? "1px solid rgba(255,255,255,0.15)" : "1px solid transparent",
                  color: sortBy === k ? "white" : "rgba(255,255,255,0.35)", fontFamily: "'Cinzel', serif",
                }}>{l}</button>
              ))}
            </div>
            <div style={{ maxHeight: 600, overflowY: "auto" }}>
              {sorted.map((c, i) => {
                const active = c.key === calc.key;
                return (
                  <button key={c.key} onClick={() => { setFormId(c.formId); setElemId(c.elemId); setIntentId(c.intentId); }} style={{
                    display: "grid", gridTemplateColumns: "180px 1fr 60px 60px 50px 100px",
                    gap: 8, alignItems: "center", padding: "10px 16px", width: "100%", textAlign: "left", cursor: "pointer",
                    background: active ? `${c.elemColor}10` : c.synergy ? "rgba(201,162,39,0.05)" : i % 2 === 0 ? "transparent" : "rgba(255,255,255,0.01)",
                    border: "none", borderBottom: "1px solid rgba(255,255,255,0.03)",
                  }}>
                    <div>
                      <span style={{ fontFamily: "'Cinzel', serif", fontSize: 13, fontWeight: 600, color: active ? c.elemColor : "rgba(255,255,255,0.7)" }}>{c.name}</span>
                    </div>
                    <div style={{ fontSize: 11, color: "rgba(255,255,255,0.3)" }}>{c.tactical}</div>
                    <div style={{ fontSize: 13, fontFamily: "'Cinzel', serif", fontWeight: 700, color: "rgba(255,255,255,0.7)", textAlign: "center" }}>{c.dmg > 0 ? c.dmg : "—"}</div>
                    <div style={{ fontSize: 12, color: "rgba(255,255,255,0.35)", textAlign: "center" }}>{c.mana}</div>
                    <div style={{ fontSize: 12, color: c.dpm >= 4 ? "#27ae60" : c.dpm >= 2 ? "#f39c12" : "rgba(255,255,255,0.3)", textAlign: "center" }}>{c.dpm > 0 ? c.dpm : "—"}</div>
                    <div style={{ fontSize: 11, color: "#C9A227", fontFamily: "'Cinzel', serif", fontWeight: c.synergy ? 700 : 400, textAlign: "right" }}>{c.synergy || ""}</div>
                  </button>
                );
              })}
            </div>
          </div>
        )}
      </div>
    </div>
  );
}
