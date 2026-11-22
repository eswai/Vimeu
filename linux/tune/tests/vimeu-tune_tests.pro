QT += core gui quick quickcontrols2 testlib network
CONFIG += c++17 testcase
TARGET = vimeu-tune_tests
TEMPLATE = app

VIMEU_ROOT = $$clean_path($$PWD/../../..)
isEmpty(VIMEU_CORE_DIR): VIMEU_CORE_DIR = $$VIMEU_ROOT/.build/release
INCLUDEPATH += ../src $$VIMEU_ROOT/Sources/CVimeu/include
LIBS += -L$$VIMEU_CORE_DIR -lvimeu
QMAKE_RPATHDIR += $$VIMEU_CORE_DIR
DEFINES += VIMEU_TEST_DIC=\\\"$$VIMEU_ROOT/dict/vimeu.dic\\\"

HEADERS += ../src/backend.h ../src/theme.h
SOURCES += vimeu-tune_tests.cpp ../src/backend.cpp ../src/theme.cpp
RESOURCES += ../src/resources.qrc
