import { GoogleGenerativeAI, type GenerativeModel } from '@google/generative-ai';

export const GEMINI_MODEL = process.env.GEMINI_MODEL ?? 'gemini-2.5-flash-lite';

export interface Project {
  name: string;
  address?: string;
}

export interface ScanRequestInput {
  imageBase64: string;
  mimeType: string;
  companyCode: string;
  projects: Project[];
}

export interface GeminiReceiptItem {
  code: string | null;
  description: string | null;
  quantity: number | null;
  price: number | null;
}

export interface GeminiReceipt {
  bounding_box: [number, number, number, number] | null;
  invoice_number: string | null;
  date: string | null;
  business_name: string | null;
  amount: number | null;
  vat: number | null;
  start_time: string | null;
  end_time: string | null;
  project_name: string | null;
  category: string;
  items: GeminiReceiptItem[];
  confidence: number;
}

export class GeminiError extends Error {
  constructor(public code: string, message: string) {
    super(message);
    this.name = 'GeminiError';
  }
}

const SYSTEM_PROMPT = `Role: Financial OCR Agent for Israeli receipts.
Input: A single image that may contain one or many receipts.
Context: A list of company projects (name + address) and a Company Code.

Instructions:
1. Detect every distinct receipt boundary in the image. Bulk shots may contain up to ~20 receipts; identify each one separately even when they overlap.
2. For each receipt, return a tight bounding box that frames only that receipt.
   - Coordinates: [ymin, xmin, ymax, xmax] normalized to 0-1000 (top-left origin).
3. Extract for each receipt — invoice_number is the HIGHEST PRIORITY field, treat it as the primary key:
   - invoice_number (PRIMARY KEY): the receipt/invoice identifier. Hebrew labels: "מספר חשבונית", "מס' חשבונית", "מס' קבלה", "חשבונית מס'". Also accept "Invoice #", "Receipt #", "מסמך מספר". Return the raw alphanumeric value with no prefix label. Set null only if truly absent on the printed receipt.
   - date (YYYY-MM-DD if possible)
   - business_name
   - amount (FINAL "Total to Pay" — see Totals rules below)
   - vat (Israeli מע"מ — see VAT rules below)
   - start_time and end_time (HH:MM, ONLY for parking receipts — entry/exit times. Null for all other categories.)
4. Totals rules (CRITICAL for Hebrew supermarket receipts — Carrefour, City Market, Shufersal, Rami Levy, Victory, etc.):
   a. The "amount" field must be the FINAL amount the customer paid AFTER all discounts. Look for the LAST total printed on the receipt — common Hebrew labels include "סה"כ לתשלום", "לתשלום", "סך הכל לתשלום", "סהכ לתשלום", "סך לתשלום".
   b. Do NOT confuse this with "Total before discounts" — Hebrew labels like "סה"כ לפני הנחה", "סכום ביניים", "סה"כ לפני הנחות", "סך הכל לפני הנחה". These are intermediate totals; ignore them for the amount field.
   c. If you see TWO totals, the LOWER one (after discounts) is the correct "amount".
5. VAT rules (Israeli מע"מ — current statutory rate is 18%, effective from January 1, 2025):
   a. If the receipt explicitly prints a VAT line (look for the Hebrew label מע"מ, the spelled form מעמ, the English VAT, or "מס ערך מוסף"), return that exact decimal number.
   b. If VAT is NOT explicitly printed AND the business is one that typically includes VAT in the displayed total (retail, restaurants, gas stations, parking, transportation, hotels, most service shops), CALCULATE the VAT portion as: vat = round(amount / 1.18 * 0.18, 2). Return this calculated value.
   c. Only return null when amount is unknown OR the business is clearly VAT-exempt (e.g. private receipts, tips, donations, foreign vendors).
   d. Pre-2025 receipts (date strictly before 2025-01-01) used 17%. If you can clearly read a pre-2025 date AND VAT is implicit, use 17% for that single receipt: vat = round(amount / 1.17 * 0.17, 2). Otherwise default to 18%.
6. CATEGORY — classify each receipt into EXACTLY ONE of these six values (return the Hebrew string exactly):
   - "הוצאות חניה" — parking lots, parking meters, "חניון", "חניה"
   - "הוצאות רכב" — fuel/gas stations, car wash, EV charging, car repairs, tires, oil change, car insurance
   - "תחבורה ציבורית" — taxi (מונית, גט, יאנגו), bus, train (רכבת ישראל), light rail, ride sharing
   - "מזון ואירוח" — restaurants, cafes, bars, supermarkets, food delivery, hotels, catering, fast food
   - "תוכנה ותקשורת" — technology and AI service providers, SaaS, cloud, software subscriptions, hosting, domain registrars, telecom/phone/internet bills. When the business_name matches a recognizable tech or AI vendor (e.g. Google, Anthropic, Claude, OpenAI, ChatGPT, AWS, Amazon Web Services, Microsoft, Azure, Adobe, GitHub, GitLab, Cloudflare, Vercel, Netlify, JetBrains, Atlassian, Slack, Zoom, Notion, Figma, Dropbox, Apple iCloud, Bezeq, HOT, Cellcom, Partner, Pelephone), classify as "תוכנה ותקשורת" regardless of any food/parking/transport interpretation.
   - "אחר" — DEFAULT FALLBACK. Use this whenever the receipt does not clearly fit any of the five categories above.
7. ITEMS — extract EVERY line item printed on the receipt:
   - DO NOT aggregate or deduplicate. If "חלב 3%" appears twice on two separate rows, return it twice as two separate item objects. Preserve printed order.
   - Each item object: { "code": string|null, "description": string|null, "quantity": number|null, "price": number|null }
     - code: product/PLU/SKU code if printed (often a 7–13 digit barcode column next to the item). Null if absent.
     - description: the item's printed name in its original language (Hebrew if Hebrew).
     - quantity: numeric quantity (default 1 when unspecified but the line is clearly a purchased item).
     - price: the LINE TOTAL for that row in the receipt's currency (quantity × unit price), as a positive number for purchases.
   - DISCOUNTS: receipts often print discount lines like "הנחה", "מבצע", "הנחת חבר", "הנחת מועדון", "הטבת קופון" with negative amounts. Represent them either as:
       a) a separate line item with description = the discount label and price = the negative amount (preferred when the discount applies to multiple items), OR
       b) by reducing the price of the specific item the discount applies to (when the discount is clearly tied to a single preceding line).
   - For pure non-supermarket receipts (parking, fuel, taxi) with no itemized breakdown, return an empty items array [].
8. Map to project_name using the provided Project List by address proximity / business name. If your confidence in the project mapping is below 85%, set project_name to null.
9. Always return a confidence value between 0.0 and 1.0 reflecting your overall extraction confidence for that receipt.
10. If no receipts are detected, return an empty array.

Output format (CRITICAL):
Return ONLY a raw JSON array. No prose, no explanation, no markdown code fences (no \`\`\`), no leading or trailing text. The very first character of your response must be \`[\` and the very last character must be \`]\`.

Each element of the array must be an object with this exact shape:
{
  "bounding_box": [ymin, xmin, ymax, xmax],
  "invoice_number": string|null,
  "date": string|null,
  "business_name": string|null,
  "amount": number|null,
  "vat": number|null,
  "start_time": string|null,
  "end_time": string|null,
  "project_name": string|null,
  "category": "הוצאות חניה" | "הוצאות רכב" | "תחבורה ציבורית" | "מזון ואירוח" | "תוכנה ותקשורת" | "אחר",
  "items": [
    { "code": string|null, "description": string|null, "quantity": number|null, "price": number|null }
  ],
  "confidence": number
}

If no receipts are found, return exactly: []
`;

let modelClient: GenerativeModel | null = null;

function getModel(): GenerativeModel {
  if (modelClient) return modelClient;
  const apiKey = process.env.GEMINI_API_KEY;
  if (!apiKey) {
    throw new GeminiError('config_missing', 'GEMINI_API_KEY is not configured');
  }
  const genAI = new GoogleGenerativeAI(apiKey);
  modelClient = genAI.getGenerativeModel({
    model: GEMINI_MODEL,
    systemInstruction: SYSTEM_PROMPT,
    generationConfig: {
      temperature: 0.2,
      responseMimeType: 'application/json',
    },
  });
  return modelClient;
}

export async function analyzeReceipts(
  input: ScanRequestInput,
): Promise<GeminiReceipt[]> {
  const model = getModel();

  const projectsBlock =
    input.projects.length === 0
      ? '(none on file yet)'
      : input.projects
          .map((p) => `- ${p.name} @ ${p.address ?? ''}`)
          .join('\n');

  const userText = `Company Code: ${input.companyCode}
Project List:
${projectsBlock}

Analyse the attached image and return the JSON array described in your instructions.
`;

  let result;
  try {
    result = await model.generateContent({
      contents: [
        {
          role: 'user',
          parts: [
            { text: userText },
            {
              inlineData: {
                mimeType: input.mimeType,
                data: input.imageBase64,
              },
            },
          ],
        },
      ],
    });
  } catch (err) {
    throw new GeminiError(
      'upstream_error',
      `Gemini call failed: ${(err as Error).message}`,
    );
  }

  const text = result.response.text();
  if (!text || text.trim() === '') {
    throw new GeminiError('empty_response', 'Empty response from model');
  }

  return parseReceipts(text);
}

function parseReceipts(raw: string): GeminiReceipt[] {
  let decoded: unknown;
  try {
    decoded = JSON.parse(raw);
  } catch (e) {
    throw new GeminiError(
      'invalid_json',
      `Could not parse model output: ${(e as Error).message}`,
    );
  }

  if (Array.isArray(decoded)) return decoded as GeminiReceipt[];
  if (
    decoded !== null &&
    typeof decoded === 'object' &&
    Array.isArray((decoded as { receipts?: unknown }).receipts)
  ) {
    return (decoded as { receipts: GeminiReceipt[] }).receipts;
  }
  throw new GeminiError('unexpected_shape', 'Unexpected response shape');
}
