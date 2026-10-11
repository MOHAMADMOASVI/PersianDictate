# PersianDictate

یک برنامهٔ کوچک برای نوار منوی macOS: حرف می‌زنید و متن **همان لحظه** در هر برنامه‌ای که فوکوس دارد تایپ می‌شود.

- فارسی و انگلیسی، با تشخیص خودکار زبان (یا انتخاب دستی)
- ترجمهٔ خودکار: فارسی بگویید و انگلیسی تایپ شود، یا انگلیسی بگویید و فارسی تایپ شود
- شروع/توقف با **⌘⇧D** یا از داشبورد
- **آنلاین است:** صدا برای تشخیص به [Groq](https://groq.com) (Whisper large-v3) فرستاده می‌شود. چیزی روی مک نصب یا دانلود نمی‌شود، ولی اینترنت و یک کلید API لازم است.

## پیش‌نیازها

- macOS 13 یا جدیدتر
- یک کلید Groq (رایگان): <https://console.groq.com/keys> — در داشبورد واردش کنید. کلید در Keychain می‌ماند.
- برای ساخت: Command Line Tools یا Xcode

## ساخت و نصب

```bash
./build.sh && cp -R build/PersianDictate.app /Applications/ && open /Applications/PersianDictate.app
```

فایل نصب: `./make-dmg.sh` همان برنامه را در `build/PersianDictate.dmg` می‌گذارد.

آیکون: `swift Scripts/make-icon.swift` آن را از نو می‌کشد و در `Resources/AppIcon.icns` می‌گذارد.

`build.sh` اگر گواهی «Apple Development» روی مک باشد با همان امضا می‌کند تا مجوز Accessibility و دسترسی Keychain بعد از هر build بماند؛ وگرنه ad-hoc امضا می‌کند و باید بعد از هر build برنامه را از فهرست Accessibility حذف و دوباره اضافه کنید.

## مجوزها

1. **Microphone** — System Settings ← Privacy & Security ← Microphone
2. **Accessibility** (برای تایپ در برنامه‌های دیگر) — System Settings ← Privacy & Security ← Accessibility

## نحوهٔ استفاده

1. مکان‌نما را جایی بگذارید که متن باید تایپ شود.
2. **⌘⇧D** را بزنید؛ آیکون قرمز می‌شود.
3. حرف بزنید. کلمه‌ها حین گفتن تایپ می‌شوند؛ با هر مکث جمله یک بار با مدل بزرگ‌تر بازبینی و اگر لازم باشد اصلاح می‌شود.
4. دوباره **⌘⇧D** برای توقف.

**داشبورد** با باز کردن برنامه (یا «داشبورد…» در منو) می‌آید: دکمهٔ شروع/توقف، متن زنده، زبان، ترجمه، شمار کلمه‌ها، وضعیت مجوزها و کلید، و تاریخچهٔ جمله‌ها با دکمهٔ کپی. تاریخچه (آخرین ۲۰۰ جمله) فقط روی همین مک در `~/Library/Application Support/PersianDictate/history.json` می‌ماند. وقتی خود داشبورد جلوی صفحه است، متن فقط در داشبورد نشان داده می‌شود.

ترجمه:
- **به انگلیسی:** هر زبانی بگویید انگلیسی تایپ می‌شود (ترجمهٔ خود Whisper).
- **به فارسی:** جمله در هر مکث با Google Translate ترجمه و یک‌جا تایپ می‌شود (حین گفتن، متن اصلی فقط در داشبورد دیده می‌شود). اگر ترجمه نشد، متن اصلی تایپ می‌شود.

نکته‌ها:
- **سقف Groq:** حساب رایگان ۲۰ درخواست در دقیقه دارد. برنامه سهم جمله‌های تمام‌شده را نگه می‌دارد؛ پس در دیکتهٔ طولانی و پشت‌سرهم، تایپ زنده کم می‌شود و متن بیشتر در مکث‌ها می‌آید. با حساب پولی: `defaults write com.persiandictate.app GroqRequestsPerMinute 100`
- اصلاح با Backspace انجام می‌شود؛ تا جمله تمام نشده مکان‌نما را جابه‌جا نکنید. اگر وسط جمله به برنامهٔ دیگری بروید، چیزی پاک نمی‌شود.
- در حالت خودکار، زبان هر جمله بعد از حدود ۱٫۵ ثانیه مشخص می‌شود؛ اگر فقط به یک زبان حرف می‌زنید، همان را انتخاب کنید.

## ساختار کد

| فایل | مسئولیت |
|---|---|
| `main.swift` | راه‌اندازی `NSApplication`؛ حالت‌های `--simulate` و `--snapshot` |
| `AppDelegate.swift` | آیکون و منوی نوار منو، وضعیت، مجوزها |
| `HotkeyManager.swift` | شورت‌کات سراسری با Carbon |
| `AudioCapture.swift` | میکروفون به‌صورت جریان PCM ‏16kHz |
| `GroqSpeech.swift` | فرستادن صدا به Groq، کلید در Keychain، رعایت سقف درخواست |
| `LiveDictation.swift` | بریدن گفتار در مکث‌ها، گذرهای زنده و نهایی، تشخیص زبان |
| `LiveText.swift` | پاک‌سازی خروجی Whisper و محاسبهٔ Backspace/تایپ |
| `TextTyper.swift` | تایپ و Backspace با `CGEvent` |
| `Translator.swift` | ترجمه به فارسی با Google Translate |
| `Dashboard.swift` | پنجرهٔ داشبورد (SwiftUI)، تاریخچه و آمار |
| `Simulation.swift` | پخش یک فایل صوتی در همان خط لوله و چاپ ویرایش‌ها |

## عیب‌یابی

- **متن تایپ نمی‌شود:** مجوز Accessibility را بررسی کنید.
- **«کلید پذیرفته نشد»:** کلید اشتباه است یا Groq از شبکهٔ شما در دسترس نیست.
- **بدون میکروفون امتحان کنید:** `GROQ_API_KEY=… .build/release/PersianDictate --simulate file.wav [auto|fa|en] [off|english|persian]`
- **لاگ برنامه:** `log stream --predicate 'process == "PersianDictate"'`
