import { NativeModule, requireNativeModule } from 'expo';

export type SaveBackupInfo = {
  name: string;
  createdAt: number;
  fileCount: number;
  totalBytes: number;
};

export type SaveSummary = {
  hasSaves: boolean;
  fileCount: number;
  totalBytes: number;
  backups: SaveBackupInfo[];
};

export type Gow3CoreEvents = {
  onSessionStateChanged: (event: { started: boolean; suspended: boolean }) => void;
};

declare class Gow3CoreModule extends NativeModule<Gow3CoreEvents> {
  /** JSON: model, RAM, task address map, footprint and limit, signing flags, JIT pool state. */
  deviceReport(): string;
  /** A debugger (StikDebug) is attached right now. */
  isDebuggerAttached(): boolean;
  /** CS_DEBUGGED is set (stays set after the debugger detaches). */
  isCsDebugged(): boolean;
  isStikDebugInstalled(): Promise<boolean>;
  /** Opens StikDebug, waits for it, creates the JIT pool and detaches. Resolves 0 on success. */
  enableJit(poolMb: number): Promise<number>;
  /** Built-in JIT: whether this install can use it (iOS 26+, helper extension present) and is paired. */
  builtInJitStatus(): Promise<{ available: boolean; reason: string; paired: boolean; pairingSupported: boolean }>;
  /** In-app pairing (iOS 27+): advertises the app as a computer to pair with from Settings. */
  startPairing(): Promise<void>;
  cancelPairing(): Promise<void>;
  /** Deletes the stored pairing file. */
  forgetPairing(): Promise<void>;
  pairingState(): Promise<{ phase: 'idle' | 'waiting' | 'pin' | 'paired' | 'failed'; pin: string; message: string; backgroundLimited: boolean; supported: boolean; paired: boolean }>;
  /** Checks LocalDevVPN and the Developer Disk Image (downloads and mounts it if needed). */
  prepareBuiltInJit(): Promise<string>;
  resetDeveloperDiskImage(): Promise<string>;
  /** The app's helper attaches the debugger, then the JIT pool is created and it detaches. Resolves 0 on success. */
  enableJitBuiltIn(poolMb: number): Promise<number>;
  /** Documents/gow3: which of the loader's files are there (from the PC's gow3 out/ folder, and game/). */
  gameFiles(): { folder: string; boot: boolean; content: boolean; patches: boolean; eboot: boolean; sfo: boolean; started: boolean; suspended?: boolean; cover?: string };
  /** Runs the game CPU-only through FEXCore (stops at the first GPU call); output goes to Documents/gow3/loader.log. */
  startGameCpuOnly(): Promise<string>;
  /** Runs the game with graphics in a fullscreen Metal view (two-finger double tap, Suspend button, or L3+R2 suspends back). */
  startGame(): Promise<string>;
  /** Re-presents the suspended game session and resumes GPU/audio without restarting or re-enabling JIT. */
  resumeGame(): Promise<string>;
  /** Cleanly suspends the active game session back to the launcher. */
  suspendGame(): Promise<string>;
  /** Frame cap in gow3.ini (20, 24, 30, 40, 60, or 0 for none), applied live when started. */
  fpsLimit(): number;
  setFpsLimit(limit: number): void;
  /** M1 TBDR profile in gow3.ini (0=Off, 1=Balanced, 2=Performance, 3=Ultra), applied live when started. */
  m1Profile(): number;
  setM1Profile(profile: number): void;
  /** On-screen controls at game start (they hide while a controller is connected; a button in game toggles them). */
  touchControlsEnabled(): boolean;
  setTouchControlsEnabled(enabled: boolean): void;
  /** Summary of Documents/gow3/user/savedata and local backups. */
  saveSummary(): SaveSummary;
  createSaveBackup(name: string): Promise<SaveBackupInfo>;
  restoreSaveBackup(name: string): Promise<string>;
  deleteSaveBackup(name: string): Promise<string>;
  exportSaves(): Promise<string>;
  importSaves(): Promise<string>;
  /** The last 24 KiB of the loader log. */
  readGameLog(): string;
  clearGameLog(): void;
  /** For a hang: every thread writes its guest and host frames to the game log. Threads signalled. */
  dumpGameThreads(): Promise<number>;
  /** MoltenVK clears a fullscreen Metal view for `seconds`; JSON: device, fps, what shadPS4 would lack. */
  gpuScreenTest(seconds: number): Promise<string>;
  /** JSON results of the memory, JIT and FEXCore self-tests. */
  runSelfTest(): Promise<string>;
  /** Connected game controllers (GameController framework). */
  controllers(): Array<{ name: string; category: string; kind: string; haptics: boolean; light: boolean; battery: number }>;
  /** Progress lines of every self-test run so far (survives a crash). */
  readLog(): string;
  clearLog(): void;
}

export default requireNativeModule<Gow3CoreModule>('Gow3Core');
