let activeContext;

async function playAlarm(volume = 0.8) {
  if (activeContext) await activeContext.close().catch(() => {});
  const context = new AudioContext();
  activeContext = context;
  const gain = context.createGain();
  gain.gain.value = Math.max(0, Math.min(1, Number(volume))) * 0.22;
  gain.connect(context.destination);
  const start = context.currentTime;
  const tones = [880, 660, 880, 660, 880, 660];
  tones.forEach((frequency, index) => {
    const oscillator = context.createOscillator();
    oscillator.type = "sine";
    oscillator.frequency.value = frequency;
    oscillator.connect(gain);
    oscillator.start(start + index * 0.32);
    oscillator.stop(start + index * 0.32 + 0.22);
  });
  setTimeout(() => context.close().catch(() => {}), 2_500);
}

chrome.runtime.onMessage.addListener((message) => {
  if (message?.target === "offscreen" && message.type === "playAlarm") void playAlarm(message.volume);
});
