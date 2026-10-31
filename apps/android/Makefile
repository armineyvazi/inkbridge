# Gradle and AGP 8.7 need JDK 17; don't depend on the shell's JAVA_HOME.
JDK17 ?= $(shell /usr/libexec/java_home -v 17 2>/dev/null || echo /opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home)
export JAVA_HOME := $(JDK17)
GRADLE := ./gradlew

.PHONY: test apk install simulate clean

test:
	$(GRADLE) :core:test

apk:
	$(GRADLE) :app:assembleDebug

install: apk
	adb install -r $(HOME)/Library/Caches/InkBridge/android-build/app/outputs/apk/debug/app-debug.apk

simulate:
	$(GRADLE) -q :simulator:run --args="$(ARGS)"

clean:
	$(GRADLE) clean
