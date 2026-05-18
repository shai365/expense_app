# Smart Expense Agent — מסמך PRD

> מסמך זה נוצר על-בסיס סקירת הקוד הקיים (Flutter, `lib/`) בענף `main` נכון ל-2026-05-12.
> הוא משמש גם כתיעוד של מה שכבר נבנה (P0) וגם כצפי לפיתוח המשך (P1/P2).

---

## 1. סקירה כללית (Overview)

**שם המוצר:** Smart Expense Agent (פנימית: `smart_expense_agent`, Flutter SDK ^3.11.5)

**מהות המוצר:**
אפליקציית מובייל (Flutter, מולטי-פלטפורמה: Android / iOS / Web / Windows / macOS / Linux)
המאפשרת לעובדי שטח / מנהלי פרויקטים בישראל **לצלם קבלות בודדות או מגש של עד ~20 קבלות בתמונה אחת**,
לחלץ באמצעות מודל Gemini 2.5 Flash את כל השדות הפיננסיים הרלוונטיים (מספר חשבונית, תאריך, סכום סופי, מע"מ, פריטים, קטגוריה, מיפוי לפרויקט),
ולאמת/לאשר את התוצאות במסך תוצאות לפני שמירה.

**הקהל היעד:** חברות ישראליות שמנהלות הוצאות לפי פרויקט (חשבוניות בעברית, מע"מ ישראלי, חניונים, תחבורה, הסעדה).

---

## 2. אסטרטגיה ויעדים (Goals)

### יעדים עסקיים
1. לקצר את זמן הזנת קבלות מהזנה ידנית של דקות פר-קבלה → לסריקה של מגש שלם תוך < 30 שניות.
2. להפחית טעויות סיווג ידני (קטגוריה / פרויקט / מע"מ) ע"י חילוץ אוטומטי + מסך אימות.
3. להבטיח שגם קבלה ללא מספר חשבונית מודפס לא תאבד, ושכפילויות יתאחדו אוטומטית.

### יעדי מוצר
- חלץ נכון את **`invoice_number`** כ-Primary Key לכל קבלה (זיהוי כפילויות).
- חלץ נכון את הסכום **לאחר** הנחות (לא ה"סה"כ לפני הנחה" — בעיה נפוצה בקבלות סופרמרקט עברי).
- חשב מע"מ ישראלי (17%) גם כשהוא לא מודפס במפורש (אלא אם העסק פטור).
- סווג כל קבלה לאחת מחמש קטגוריות סגורות בעברית.

### לא-יעדים (Out of Scope לפאזה הנוכחית)
- ניהול משתמשים מלא (נכון להיום: רק "Company Code" שמור ב-`SharedPreferences`).
- אינטגרציה חיה ל-ERP חיצוני.
- ייצוא ל-Excel/CSV.
- מצב Offline אמיתי (האפליקציה מחייבת אינטרנט בעת קריאה ל-Gemini).

---

## 3. ארכיטקטורה קיימת (לפי הקוד)

### Stack
| שכבה | טכנולוגיה |
|---|---|
| UI | Flutter / Material 3, ערכת נושא ב-`lib/theme/app_theme.dart` |
| State | `StatefulWidget` מקומי; אין Provider/Bloc/Riverpod |
| Auth | `shared_preferences` (`AuthService` עם `company_code` בלבד) |
| צילום / בחירה מגלריה | `image_picker` ^1.2.2 |
| עיבוד תמונה | `image` ^4.8.0 (decode/resize/encodeJpg, Crop ב-`compute` isolate) |
| AI | `google_generative_ai` ^0.4.7 — מודל `gemini-2.5-flash`, `temperature: 0.2`, `apiVersion: v1` |
| Secrets | `flutter_dotenv` (`.env`) **+** `--dart-define=GEMINI_API_KEY=...` (dart-define מנצח) |

### מבנה תיקיות
```
lib/
  main.dart                       # AuthGate → Login | Home
  config/api_config.dart          # GEMINI_API_KEY + USE_MOCK_GEMINI
  models/receipt.dart             # Receipt, ReceiptItem, BoundingBox, ReceiptCategory
  services/
    auth_service.dart             # SharedPreferences
    gemini_service.dart           # System prompt + parse + dedup + image optimize
    image_cropper.dart            # crops לפי bounding box ב-isolate
  screens/
    login_screen.dart             # קלט Company Code (A-Z, 0-9, '-', 4+ תווים)
    home_screen.dart              # תפריט — היום רק "Scan receipts"
    capture_screen.dart           # מצלמה / גלריה → Gemini → crop → Results
    results_screen.dart           # רשימת ReceiptCard + Re-scan / Confirm all
  widgets/receipt_card.dart       # כרטיס + Drill-down (פריטים, מקור)
  theme/app_theme.dart            # כחול #1E3A8A
```

### זרימת המשתמש (Happy Path)
1. **Login** — המשתמש מזין `Company Code` (לדוגמה `ACME-2025`). אין שרת — הקוד נשמר רק לוקלית.
2. **Home** — מציג את הקוד + כרטיס יחיד "Scan receipts".
3. **Capture** — בחירה בין מצלמה / גלריה (`maxWidth: 2048, imageQuality: 88`).
4. **Optimize** — אם הצד הארוך של התמונה > 1024 px, הקטנה ל-1024 + encode JPEG quality 80.
5. **Gemini call** — שליחת תמונה + System prompt בעברית/אנגלית + `Company Code` + רשימת פרויקטים *(כרגע ריקה — ראה Gap-1)*.
6. **Parse** — חילוץ JSON גולמי (`[...]`), ניקוי code-fences, fallback ל-`{ receipts: [...] }`.
7. **Dedup** — לפי `invoice_number` מנורמל; אם null בשני הצדדים — לפי `business + date + amount`. המנצח לפי confidence; שדות חסרים ממוזגים מהמפסיד.
8. **Crop** — לכל `Receipt` עם `boundingBox` נשמר `croppedImage` (JPEG q=82) ב-isolate.
9. **Results** — `Summary` (סה"כ + כמה < 85% confidence) → רשימת `ReceiptCard` → "Re-scan" / "Confirm all".

---

## 4. מודל נתונים (כפי שמוגדר ב-`lib/models/receipt.dart`)

### `Receipt`
| שדה | טיפוס | מקור | הערות |
|---|---|---|---|
| `id` | `String` | מקומי (`r1`, `r2`, …) | לא מ-Gemini, נוצר ב-parser. |
| `invoiceNumber` | `String?` | **Primary Key** | תוויות עבריות: מספר חשבונית / מס' קבלה. |
| `date` | `String?` | `YYYY-MM-DD` |  |
| `businessName` | `String?` |  |  |
| `amount` | `double?` | "סה"כ לתשלום" **לאחר** הנחות |  |
| `vat` | `double?` | מע"מ ישראלי (17%) | מחושב אוטומטית אם לא מודפס. |
| `startTime` / `endTime` | `String?` | `HH:MM` | רק לקטגוריית "הוצאות חניה". |
| `projectName` | `String?` | מיפוי לפרויקט | null אם confidence < 85%. |
| `category` | `String` | אחד מ-5 ערכים סגורים | ר' למטה. |
| `items` | `List<ReceiptItem>` | קוד ברקוד + תיאור + כמות + מחיר | כולל שורות הנחה (price שלילי). |
| `confidence` | `double` | 0.0–1.0 |  |
| `boundingBox` | `BoundingBox?` | `[yMin,xMin,yMax,xMax]` | מנורמל 0–1 או 0–1000. |
| `croppedImage` | `Uint8List?` | חתוך לוקלית | mutable — נדבק אחרי `compute`. |

### `ReceiptCategory` (5 ערכים סגורים, עברית בלבד)
- `הוצאות חניה`
- `הוצאות רכב`
- `תחבורה ציבורית`
- `מזון ואירוח`
- `אחר` (ברירת מחדל / fallback)

---

## 5. דרישות פונקציונליות

### FR-1 — התחברות (קיים)
- שדה `Company Code` יחיד: 4+ תווים, רק `A-Z`, `0-9`, `-` (מאולץ Uppercase).
- שמירה ב-`SharedPreferences`, מפתח `company_code`.
- `Sign out` מנקה את הערך וחוזר ל-Login.
- **Gap:** אין אימות מול backend; קוד שגוי עדיין מתקבל.

### FR-2 — מסך בית (קיים, מינימלי)
- מציג את `companyCode` ו-CTA "Scan receipts".
- **Gap:** אין רשימת היסטוריה / פרויקטים / סטטיסטיקות.

### FR-3 — סריקת קבלות (קיים)
- בחירה בין מצלמה לגלריה.
- אינדיקטור סטטוס דינמי: `Reading image… / Asking Gemini… / Cropping N receipts…`.
- חסימת מסך (`AbsorbPointer`) בזמן עבודה.
- שגיאת UX: SnackBar בצבע אדום בכל כשל; SnackBar רגיל אם לא זוהו קבלות.
- **Gap:** אין retry; אין ביטול בזמן הקריאה ל-Gemini.

### FR-4 — חילוץ AI (קיים, מתועד ב-system prompt ב-`gemini_service.dart`)
חוזה הפלט עם המודל (קריטי):
1. **חזרה רק כ-JSON array גולמי** — בלי markdown, בלי הסבר.
2. כל אובייקט חייב לכלול את כל השדות מהטבלה ב-§4.
3. כללי "Totals" — תפיסת הסכום **הסופי** (אחרי הנחות); התעלמות מ-"סה"כ לפני הנחה".
4. כללי VAT — אם לא מודפס, חישוב `round(amount / 1.17 * 0.17, 2)` (אלא אם פטור).
5. כללי Items — אסור לאחד שורות זהות; שמירה על סדר ההדפסה; שורות הנחה כשורה נפרדת או הפחתה משורת המקור.
6. מיפוי לפרויקט: רק אם confidence ≥ 85%, אחרת `null`.
7. אם אין קבלות — להחזיר `[]`.

### FR-5 — איחוד כפילויות (קיים, `_deduplicate`)
- **שלב 1:** התאמה לפי `invoice_number` מנורמל (trim + lower-case).
- **שלב 2 (fallback):** אם invoice_number ריק בשני הצדדים — התאמה רק כש-`businessName` + `date` + `amount` זהים (סכום: סבילות 0.005₪).
- מיזוג: המנצח לפי `confidence` הגבוה; שדות null במנצח מולאים מהמפסיד; `category` "אחר" נדחקת ע"י קטגוריה ספציפית של המפסיד; `items` נשמרים מהמנצח אם לא ריקים.

### FR-6 — חיתוך תמונה (קיים, `ImageCropper`)
- רץ ב-`compute` isolate (לא חוסם UI).
- ה-`boundingBox` של Gemini במערכת `[ymin, xmin, ymax, xmax]` עם top-left origin; קוד-המודל מנרמל גם 0–1 וגם 0–1000.
- חיתוך נופל החוצה אם רוחב או גובה < 16 px.

### FR-7 — מסך תוצאות (קיים)
- כותרת: "N receipts detected".
- בלוק `Summary` עליון: כמה מתחת ל-85% confidence.
- כרטיס `ReceiptCard` לכל קבלה:
  - thumbnail 88×110 מהחיתוך (placeholder `#1`,`#2`... אם אין).
  - `Hero` transition ל-fullscreen viewer (`InteractiveViewer`, zoom 1–6x).
  - שם עסק + chip confidence (אדום אם <85%).
  - שורות meta: Date / Invoice # / Time (רק לחניה).
  - chip קטגוריה ניתן ללחיצה → bottom-sheet בחירה מ-5 הקטגוריות.
  - סכום ב-₪.
  - bar פרויקט: ירוק אם משויך, צהוב "choose manually" אם לא.
  - Tap → bottom-sheet "פרטי קבלה" עם רשימת `items` (הנחות בצבע ירוק, מחיר שלילי).
- כפתורים תחתונים: `Re-scan` (חזרה) / `Confirm all` (**לא ממומש** — מציג SnackBar "Saving to local DB is not implemented yet").

### FR-8 — Mock Mode (קיים, debug-only)
- `flutter run --dart-define=USE_MOCK_GEMINI=true` → טוען 4 קבלות דמה (דלק / חניה / קפה לנדוור / קרפור) ב-600ms.
- מכובד **רק ב-`kDebugMode`**.

---

## 6. דרישות לא-פונקציונליות

### NFR-1 — ביצועים
- אופטימיזציית תמונה: Long side ≤ 1024 px, JPEG q=80 לפני שליחה ל-API → צמצום משמעותי של עלות + latency.
- Crop רץ ב-isolate נפרד (`compute`) כדי לא להקפיא את ה-UI.
- יעד: pipeline שלם (Capture → Results) של מגש 5–10 קבלות תוך **< 15 שניות** ברשת תקינה.

### NFR-2 — אבטחה
- **קיים:** `GEMINI_API_KEY` נטען מ-`.env` או מ-`--dart-define` (dart-define מקבל עדיפות).
- **Gap קריטי:** `.env` מוצהר כ-asset ב-`pubspec.yaml` → המפתח **משוכפל ל-binary של ה-build**. בכל build חתום למוצר חיצוני יש לעבור ל-proxy backend (לא לקרוא ישירות ל-Gemini מהלקוח).
- אין שום שימוש ב-secure storage; `Company Code` ב-plain text ב-SharedPreferences (סביר, אינו סוד).

### NFR-3 — אמינות
- Parser ה-JSON עמיד: trim, ניקוי \`\`\`code fences\`\`\`, fallback ל-substring בין סוגריים, גם `Map { receipts: [...] }`.
- כל פעולה אסינכרונית עטופה ב-try/catch + SnackBar שגיאה.

### NFR-4 — קוד / איכות
- אין כרגע **שום** טסטים אוטומטיים (אין `test/`).
- `analysis_options.yaml` עם `flutter_lints` ^6.

---

## 7. ממצאי סקירת קוד (Code Review)

### ✅ נקודות חוזק
1. הפרדה נקייה Service ↔ Screen ↔ Widget ↔ Model.
2. System prompt מאוד מפורט ומותאם לעברית/ישראל — מסביר במפורש את ההבדל בין "סה"כ לפני הנחה" ל"סה"כ לתשלום".
3. Dedup חכם עם fallback ע"י שילוב שדות, ולא רק לפי PK בודד.
4. שימוש נכון ב-`compute` ל-crop כדי לא לחסום UI thread.
5. עטיפה עמידה של JSON parsing.

### ⚠ פערים / סיכונים (Gap List)

| # | חומרה | תיאור | מיקום |
|---|---|---|---|
| **G-1** | גבוהה | `projects: []` נשלח תמיד ריק → Gemini לא יכול למפות `projectName`. צריך מקור נתונים לפרויקטים (Firestore / API / מקומי). | `capture_screen.dart:63` (לא מועבר), `gemini_service.dart:133` |
| **G-2** | גבוהה | `Confirm all` הוא placeholder עם SnackBar. אין שכבת persistence (DB/API). אובדן נתונים בכל סגירה. | `results_screen.dart:92-100` |
| **G-3** | קריטי (Prod) | `.env` כ-asset = המפתח נחשף ב-APK/IPA. עבור משתמשים חיצוניים — חייב backend proxy. | `pubspec.yaml:60`, `api_config.dart` |
| **G-4** | בינונית | שיעור המע"מ קבוע בקוד על 17%; שיעור המע"מ הישראלי **עלה ל-18% ב-2025-01-01**. ה-prompt לא עודכן. | `gemini_service.dart:82` (system prompt) |
| **G-5** | בינונית | `_openOriginalImage` ו-`_openDrillDown` מוגדרות כפונקציות top-level בקובץ widget — קשה לבדוק / להזריק תלויות. | `widgets/receipt_card.dart:152, 164` |
| **G-6** | בינונית | אין retry אוטומטי לקריאת Gemini; אין timeout מפורש; אין הצגת cost/tokens. |  |
| **G-7** | נמוכה | `Company Code` ב-SharedPreferences ללא ולידציה מול שרת — אפשר להזין כל ערך מעל 4 תווים. | `auth_service.dart`, `login_screen.dart:32` |
| **G-8** | נמוכה | אין `test/` כלל — חסרים unit tests ל-`_deduplicate`, `optimizeForApi`, `Receipt.fromJson`, `_extractJson`. |  |
| **G-9** | נמוכה | אין i18n: כפתורים באנגלית, קטגוריות בעברית, חלק מהטקסטים מעורבבים. | UI strings |
| **G-10** | נמוכה | אין logging מובנה / analytics. שגיאות גלויות רק ב-SnackBar וב-`print` של ה-toolchain. |  |

---

## 8. Roadmap מוצע

### Phase 0 — מה שכבר נבנה (✅ Done)
לוגיקת חילוץ AI + UI לאימות + dedup + crop + mock mode.

### Phase 1 — להפוך למוצר אמיתי (P0 לפאזה הבאה)
1. **Backend proxy** ל-Gemini (G-3): Cloud Function / Node — להעביר את ה-key מהלקוח.
2. **Persistence** (G-2): Firestore / Supabase / SQLite מקומי בשלב ראשון.
3. **Project List** (G-1): טעינה מ-backend לפי `companyCode`; הזרמה ל-Gemini.
4. **Authentication אמיתי** (G-7): אימות `companyCode` מול backend; אופציונלית OTP במייל.
5. **עדכון מע"מ ל-18%** (G-4) + הפיכת השיעור לקונפיגורבילי לפי תאריך הקבלה.
6. **Tests** ל-`_deduplicate`, `_parseReceipts`, `_extractJson`, `BoundingBox.normalized`.

### Phase 2 — איכות וחוויה
- ייצוא לאקסל / CSV / PDF.
- היסטוריית סריקות + חיפוש.
- עריכת שדות חופשית בכרטיס (לא רק קטגוריה).
- בחירה ידנית של פרויקט מתוך dropdown.
- i18n מלא (he/en).
- Analytics + Crashlytics.
- Retry + circuit breaker ל-Gemini, הצגת cost/tokens משוערים.

### Phase 3 — Integrations
- Webhook ל-ERP (Priority / SAP / חשבשבת).
- אישור ראש צוות / מנהל לפני הסליקה.
- OCR לחשבוניות סרוקות (PDF, לא רק תמונה).

---

## 9. הצלחה — KPIs מוצעים
| KPI | יעד |
|---|---|
| זמן ממוצע מ-Capture ל-Confirm לקבלה בודדת | < 5 שניות |
| זמן ממוצע ל-tray של 10 קבלות | < 20 שניות |
| % קבלות עם confidence ≥ 0.85 | ≥ 80% |
| % קבלות עם `invoiceNumber` מזוהה | ≥ 90% |
| % קבלות עם `projectName` ממופה אוטומטית (אחרי Phase 1) | ≥ 70% |
| % שגיאות JSON מ-Gemini שלא הצליחו להיפרסר | < 1% |

---

## 10. הנחות ותלויות
- מודל: **Gemini 2.5 Flash** עם `temperature: 0.2`. שינוי לדגם אחר ידרוש כיוון מחדש של ה-system prompt.
- שפת קלט: עברית (תוויות חשבונית). אנגלית נתמכת חלקית.
- האפליקציה דורשת **חיבור אינטרנט פעיל** בעת הסריקה (אין offline queue).
- הרשאות OS: מצלמה + גלריה (נדרשות הצהרות Info.plist / AndroidManifest שלא נסקרו במסמך זה).
