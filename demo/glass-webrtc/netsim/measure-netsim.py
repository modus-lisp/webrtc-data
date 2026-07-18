import asyncio, json, sys, time
from playwright.async_api import async_playwright
async def main(url, out, secs):
    series=[]; connected_at=None; stats={}
    async with async_playwright() as p:
        b=await p.chromium.launch(args=["--no-sandbox"]); pg=await b.new_page(viewport={"width":900,"height":500})
        t0=[None]
        def onc(m):
            t=m.text
            if t.startswith("PERF ") and t0[0] is not None:
                _,ts,fps,kbps,mps,buf=t.split(); series.append([round(time.monotonic()-t0[0],2),float(fps),float(kbps),float(buf)])
        pg.on("console", onc)
        ts=time.monotonic(); await pg.goto(url)
        dtls_at=[None]
        for _ in range(80):                              # up to 40s to bring RFB up over a bad link
            txt=await pg.locator("#hud").text_content()
            if txt and "connected" in txt and dtls_at[0] is None: dtls_at[0]=round(time.monotonic()-ts,1)
            if txt and "glass-term" in txt: connected_at=round(time.monotonic()-ts,1); break
            await pg.wait_for_timeout(300)
        if connected_at is None:
            print("@@RESULT connect=NONE"); await b.close(); json.dump({"series":[],"connect_s":None,"stats":{}},open(out,"w")); return
        await pg.mouse.click(300,200); await pg.wait_for_timeout(400)
        await pg.keyboard.type("while true; do printf '\\rP %s' \"$RANDOM$RANDOM$RANDOM\"; done", delay=40)
        await pg.keyboard.press("Enter"); await pg.wait_for_timeout(1500); t0[0]=time.monotonic()
        await pg.wait_for_timeout(int(secs*1000))
        try: stats=await pg.evaluate("fetch('/stats').then(r=>r.json()).catch(()=>({}))")
        except Exception: stats={}
        await pg.screenshot(path=out.replace(".json",".png")); await b.close()
    fps=sorted(r[1] for r in series); med=fps[len(fps)//2] if fps else 0
    kbps=max((r[2] for r in series),default=0)
    json.dump({"series":series,"connect_s":connected_at,"stats":stats},open(out,"w"))
    print(f"@@RESULT dtls={dtls_at[0]}s rfb={connected_at}s fps={med} srtt={stats.get('srtt-ms',-1)} rtx={stats.get('rtx',0)} drops={stats.get('drops',0)} cwnd={stats.get('cwnd',0)} peakKBs={round(kbps,1)}")
asyncio.run(main(sys.argv[1], sys.argv[2], float(sys.argv[3])))
