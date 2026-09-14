export namespace main {
	
	export class Config {
	    deviceName: string;
	    resolution: string;
	    maxFps: number;
	    audioEnabled: boolean;
	    hardwareDecode: boolean;
	    h265: boolean;
	    preferNewestConnection: boolean;
	    idleTimeoutSeconds: number;
	    requirePin: boolean;
	    pinCode: string;
	    launchAtStartup: boolean;
	    startMinimized: boolean;
	    autoStartMirroring: boolean;
	    alwaysOnTop: boolean;
	    theme: string;
	    firstRun: boolean;
	    verboseLogging: boolean;
	    loadError?: string;
	    logWarning?: string;
	
	    static createFrom(source: any = {}) {
	        return new Config(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.deviceName = source["deviceName"];
	        this.resolution = source["resolution"];
	        this.maxFps = source["maxFps"];
	        this.audioEnabled = source["audioEnabled"];
	        this.hardwareDecode = source["hardwareDecode"];
	        this.h265 = source["h265"];
	        this.preferNewestConnection = source["preferNewestConnection"];
	        this.idleTimeoutSeconds = source["idleTimeoutSeconds"];
	        this.requirePin = source["requirePin"];
	        this.pinCode = source["pinCode"];
	        this.launchAtStartup = source["launchAtStartup"];
	        this.startMinimized = source["startMinimized"];
	        this.autoStartMirroring = source["autoStartMirroring"];
	        this.alwaysOnTop = source["alwaysOnTop"];
	        this.theme = source["theme"];
	        this.firstRun = source["firstRun"];
	        this.verboseLogging = source["verboseLogging"];
	        this.loadError = source["loadError"];
	        this.logWarning = source["logWarning"];
	    }
	}
	export class EngineSnapshot {
	    status: string;
	    deviceName?: string;
	    deviceModel?: string;
	    // Go type: time
	    connectedAt?: any;
	    videoReceived: boolean;
	    setupKind?: string;
	    setupProgress: number;
	    lastError?: string;
	    pinCode?: string;
	    backend: string;
	
	    static createFrom(source: any = {}) {
	        return new EngineSnapshot(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.status = source["status"];
	        this.deviceName = source["deviceName"];
	        this.deviceModel = source["deviceModel"];
	        this.connectedAt = this.convertValues(source["connectedAt"], null);
	        this.videoReceived = source["videoReceived"];
	        this.setupKind = source["setupKind"];
	        this.setupProgress = source["setupProgress"];
	        this.lastError = source["lastError"];
	        this.pinCode = source["pinCode"];
	        this.backend = source["backend"];
	    }
	
		convertValues(a: any, classs: any, asMap: boolean = false): any {
		    if (!a) {
		        return a;
		    }
		    if (a.slice && a.map) {
		        return (a as any[]).map(elem => this.convertValues(elem, classs));
		    } else if ("object" === typeof a) {
		        if (asMap) {
		            for (const key of Object.keys(a)) {
		                a[key] = new classs(a[key]);
		            }
		            return a;
		        }
		        return new classs(a);
		    }
		    return a;
		}
	}

}

