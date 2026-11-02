# AGP requires JDK 17+. Prefer a real JDK 17 over a stale JAVA_HOME (e.g. Homebrew openjdk@11).
JDK17 := $(shell /usr/libexec/java_home -v 17 2>/dev/null)
ifeq ($(JDK17),)
JDK17 := /opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home
endif
ifneq ($(wildcard $(JDK17)/bin/java),)
export JAVA_HOME := $(JDK17)
endif
GRADLE := ./gradlew

.PHONY: test apk install simulate clean lint

test:
	$(GRADLE) :core:test :app:testDebugUnitTest

lint:
	$(GRADLE) :app:lintDebug

apk:
	$(GRADLE) :app:assembleDebug

install: apk
	adb install -r $(HOME)/Library/Caches/InkBridge/android-build/app/outputs/apk/debug/app-debug.apk

simulate:
	$(GRADLE) -q :simulator:run --args="$(ARGS)"

clean:
	$(GRADLE) clean

# Renders every screen at the Note Air's resolution into SHOTS (design review, no device needed).
SHOTS ?= $(HOME)/Library/Caches/InkBridge/screenshots
screenshots:
	$(GRADLE) :app:testDebugUnitTest --tests '*ScreenshotTest*' -Dinkbridge.screenshots=$(SHOTS) --rerun
