// Fora do navegador (testes na VM): nada toca.
void unlock() {}
void beep() {}
void startFlatline() {}
void stop() {}
bool isSuspended() => false;
bool loadPref(String tipo) => false;
void savePref(String tipo, bool on) {}
