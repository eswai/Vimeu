# vimeu-tune: the tuning window for vimeu on Linux (DESIGN.md §8.6).
# Links the Swift core, libvimeu.so, built at the repository root by
#   swift build -c release --product vimeu
QT += core gui qml quick quickcontrols2 network

CONFIG += c++17 release
TARGET = vimeu-tune
TEMPLATE = app

VIMEU_ROOT = $$clean_path($$PWD/../..)
isEmpty(VIMEU_CORE_DIR): VIMEU_CORE_DIR = $$VIMEU_ROOT/.build/release
isEmpty(VIMEU_CORE_INSTALL_DIR): VIMEU_CORE_INSTALL_DIR = /usr/lib/vimeu

INCLUDEPATH += $$VIMEU_ROOT/Sources/CVimeu/include
LIBS += -L$$VIMEU_CORE_DIR -lvimeu
# Development builds find libvimeu.so in the build tree first; an install
# build (CONFIG+=vimeu_install) only ever looks where the package puts it.
vimeu_install {
    QMAKE_RPATHDIR += $$VIMEU_CORE_INSTALL_DIR
} else {
    QMAKE_RPATHDIR += $$VIMEU_CORE_DIR $$VIMEU_CORE_INSTALL_DIR
}

HEADERS += \
    src/backend.h \
    src/theme.h

SOURCES += \
    src/main.cpp \
    src/backend.cpp \
    src/theme.cpp

RESOURCES += src/resources.qrc
