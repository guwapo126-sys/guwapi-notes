# guwapi notes

Scopul acestui build este să confirme trei lucruri pe iPhone-ul tău, înainte de aplicația completă:

1. Aplicația se instalează cu contul Apple gratuit.
2. Reminderele trimit notificări.
3. Widgetul de pe ecranul de blocare afișează nota. Acesta e punctul incert.

## 1. Build pe GitHub (de pe laptopul Ubuntu)

```bash
cd guwapi-notes
git init -b main
git add .
git commit -m "guwapi notes: build de test"
gh repo create guwapi-notes --private --source=. --push   # sau creează repo-ul din browser și fă git push
```

GitHub → repo → **Actions** → **Build IPA**. Pornește singur la push și durează cam 5–10 minute.
Când e gata, descarci artifactul **GuwapiNotes-ipa** de jos din pagină. Este un zip care conține `GuwapiNotes.ipa`.

> Pe un repo privat, minutele de macOS sunt limitate pe planul gratuit GitHub. Pentru câteva build-uri pe lună ajung.

## 2. Instalare (de pe PC-ul Windows, cu iloader)

Ce trebuie să ai înainte:
- **iTunes** sau aplicația **Apple Devices**, ca Windows să vadă iPhone-ul prin USB.
- iPhone conectat prin cablu și setat pe „Ai încredere în acest computer”.

Ai două variante:

**A. Recomandat: prin SideStore.** Reîmprospătarea la 7 zile se face apoi de pe telefon, fără PC.
1. În iloader instalezi **SideStore** pe iPhone, dacă nu e deja.
2. Pe iPhone: Setări → Confidențialitate și securitate → **Mod dezvoltator** → activat (telefonul repornește).
3. Copiezi `GuwapiNotes.ipa` pe iPhone, de exemplu prin iCloud Drive, Telegram sau mail.
4. Fișierul .ipa → Partajează → **SideStore**, sau în SideStore: My Apps → **+** → alegi .ipa.

**B. Direct din iloader:** importi `.ipa`-ul și îl instalezi. Merge, dar la fiecare 7 zile îl reinstalezi din PC.

Cu contul gratuit:
- Poți avea maxim 3 aplicații active, inclusiv SideStore.
- Aplicația și widgetul consumă 2 din cele 10 App ID-uri pe săptămână.

## 3. Test pe telefon

1. Deschide **guwapi notes** și permite notificările.
2. Iconița stetoscop → **Diagnostic**:
   - **Legătura app ↔ widget: OK (verde)** înseamnă că widgetul va funcționa. Dacă e **LIPSĂ (roșu)**, fă un screenshot.
   - **Trimite notificare de test în 10 s**, apoi blochează telefonul și verifică dacă apare.
3. Creează o notă cu client, bifează **Fixează pe ecranul de blocare** și pune un reminder peste 2–3 minute.
4. Ține apăsat pe ecranul de blocare → **Personalizează** → ecran de blocare → adaugă widgetul **guwapi notes** (dreptunghiular).
5. Verifică:
   - widgetul arată nota sau reminderul;
   - notificarea vine la ora setată;
   - atingerea notificării deschide nota.

Trimite-mi rezultatul: screenshot din Diagnostic și din ecranul de blocare.

## Structură

| Fișier | Ce face |
|---|---|
| `project.yml` | Definiția proiectului (XcodeGen); GitHub o transformă în proiect Xcode |
| `Shared/Shared.swift` | Culorile brandului, modelul de notă, stocarea comună app + widget |
| `App/` | Aplicația: lista pe clienți, editorul, reminderele, diagnosticul |
| `Widget/` | Widgeturile pentru ecranul de blocare și ecranul principal |
| `.github/workflows/build.yml` | Compilarea pe Mac-ul din cloud și producerea `.ipa` |

Culoarea de accent se schimbă din `Shared/Shared.swift` → `Brand.accent`.

## Versiunea 0.2

- Foldere în foldere (client → aplicație → note), fiecare cu culoare și iconiță.
- Editor text formatat: Titlu, H1–H3, Cod, bold, italic, subliniat, tăiat, culori de text, evidențiere, fonturi (Standard, Rotunjit, Serif, Monospace), mărime.
- Liste: bullet, numerotate, checklist (atinge cercul ca să bifezi). Enter continuă lista; Enter pe rând gol o închide.
- Poze în notă, scanare document → text (Vision, local), Live Text din cameră.
- Culoare pe fiecare notă; vizualizare carduri sau listă compactă (butonul din dreapta sus).
- Etichete: scrie `#client` sau `#urgent` oriunde în notă. Căutare în toate notele.
- Șabloane predefinite + salvarea oricărei note ca șablon. Export Markdown și PDF.
- Widget: notele fixate și următorul reminder, cu culoarea notei.
- Notele din build-ul de test se mută automat, grupate pe client.

## Versiunea 0.3

- Import din Fișiere: Markdown, TXT, RTF, HTML, PDF sau un folder întreg (cu subfoldere), din meniul + al oricărui folder.
- Scanare: paragrafe reconstruite, rânduri nesigure marcate (imaginea rândului / text marcat / omis), sensibilitate reglabilă.
- Meniul Layout din editor: unește rânduri, curăță textul, mută paragrafe, aliniere, indentare, separator.

## Versiunea 0.5

- Status pe note (Problemă / În lucru / Gata): bulina din listă ia culoarea statusului; filtre în folder.
- Ordine manuală: ții apăsat pe o notă și o tragi peste alta; peste un subfolder o muți în el. Sortare din ⇅.
- Etichete separate de text (# din note nu mai creează etichete): 🔥 Urgent, 💡 Idee, 💬 De discutat, 💪 În lucru, 💀 Jale, 🚨 Decizie client + etichete proprii din „Gestionează etichetele”.

## Versiunea 0.6

- Import PDF cu structură: titluri după mărimea fontului, paragrafe, liste, tabele cu 2 coloane, imagini la locul lor; antet/subsol repetate eliminate. PDF scanat → paginile ca imagini.
- Buton pe ecranul de blocare / Centrul de control cu glyph-ul guwapi (scut + rânduri), deschide aplicația.
- Widgeturi refăcute: „guwapi · Note” (status, etichete, client) și „guwapi · Status” (probleme / în lucru / gata, urgente).
- Diagnostic legat de widget: verde (actualizat recent), galben (conectat, dar nepus/neactualizat), roșu (fără legătură); iconița de diagnostic ia aceeași culoare.
- Cerință minimă: iOS 18.

## Versiunea 0.7

- 5 statusuri: ⚪ De făcut · 🟡 În lucru · 🟣 De verificat · 🔴 Problemă · 🟢 Gata.
- Etichete: 🔥 Urgent · 🚨 Decizie client · 💡 Idee · 💬 De discutat · 🐛 Bug · 🔒 Securitate · 💀 Jale. Eticheta „În lucru” devine status (migrare automată).
- Ecran de proiect: rezumat „X rămase din Y”, bară de progres, filtre pe status, note grupate pe status (implicit), „Gata” strânse.
- Atingi bulina (listă) sau eticheta de status (card) și schimbi statusul direct; în modul grupat, tragi o notă în alt grup și preia statusul lui.
