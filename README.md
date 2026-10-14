# betlify-tips

Daily tips feed for the Betlify app.

`generate.ps1` pulls real fixtures from ESPN's public scoreboard API for football, basketball and tennis, picks a tip for each suitable match, settles finished matches (WON/LOST + score) and writes [`tips.json`](tips.json). A GitHub Actions workflow runs it every 3 hours and commits the result; the app downloads:

```
https://raw.githubusercontent.com/miloradstancic7-bot/betlify-tips/main/tips.json
```

## How tips are picked

- **Football**: bookmaker (DraftKings) odds for 1 / X / 2 and over/under 2.5 goals, margin removed. The most likely market priced at 1.30 or more is the pick; matches under 50% are skipped.
- **Basketball** (NBA, EuroLeague): moneyline favourite at 1.25 or more, otherwise the favourite's handicap.
- **Tennis** (ATP, WTA singles): the feed has no odds, so the win chance and the odds are estimated from rankings. Only matches where both players are ranked, and the analysis says the odds are an estimate.
- Confidence = that probability. Up to 10 tips a day go to **Free** (60% and up), up to 15 more to **Extra**. Each day also gets a **Daily Combo** of the three safest bookmaker-priced picks.
- A tip is never changed after it is published, only its result, so the record is honest.

Run it locally (Windows PowerShell 5.1 or PowerShell 7):

```
powershell -ExecutionPolicy Bypass -File generate.ps1
```

18+ · Tips are probabilities, not guarantees. Bet responsibly.
