// Minimal Dobby header stub for AccDemoArcaea.
// Real libdobby.a is downloaded by CI from
// https://github.com/jmpews/Dobby/releases (or built locally).
//
// We only use DobbyHook / DobbySymbolResolver here.
#ifndef DOBBY_H
#define DOBBY_H

#ifdef __cplusplus
extern "C" {
#endif

int  DobbyHook(void *address, void *replace_call, void **origin_call);
int  DobbyDestroy(void *address);
void *DobbySymbolResolver(const char *image_name, const char *symbol_name);

#ifdef __cplusplus
}
#endif

#endif // DOBBY_H
