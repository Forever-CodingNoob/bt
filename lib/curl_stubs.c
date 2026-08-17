/* Minimal libcurl binding. The sandbox ships libcurl.so.4 but no curl.h,
   so the handful of easy-API symbols and ABI constants (frozen since
   libcurl 7.x) are declared by hand. */
#include <stdio.h>
#include <caml/mlvalues.h>
#include <caml/alloc.h>
#include <caml/memory.h>

typedef void CURL;
typedef int CURLcode;
struct curl_slist;

extern CURLcode curl_global_init(long flags);
extern CURL *curl_easy_init(void);
extern CURLcode curl_easy_setopt(CURL *handle, int option, ...);
extern CURLcode curl_easy_perform(CURL *handle);
extern CURLcode curl_easy_getinfo(CURL *handle, int info, ...);
extern void curl_easy_cleanup(CURL *handle);
extern struct curl_slist *curl_slist_append(struct curl_slist *list,
                                            const char *string);
extern void curl_slist_free_all(struct curl_slist *list);
extern const char *curl_easy_strerror(CURLcode code);

#define BT_CURLOPT_WRITEDATA 10001
#define BT_CURLOPT_URL 10002
#define BT_CURLOPT_ERRORBUFFER 10010
#define BT_CURLOPT_HTTPHEADER 10023
#define BT_CURLOPT_NOSIGNAL 99
#define BT_CURLINFO_RESPONSE_CODE 2097154
#define BT_CURL_GLOBAL_DEFAULT 3
#define BT_CURL_ERROR_SIZE 256

/* url -> header line -> output path -> (http_status, error_message);
   http_status is 0 on transport failure, error_message is "" on success.
   The whole transfer runs under the OCaml runtime lock: bt is a
   single-threaded CLI that blocks on the fetch anyway. */
value bt_curl_get(value v_url, value v_header, value v_out)
{
  CAMLparam3(v_url, v_header, v_out);
  CAMLlocal1(result);
  static int initialized = 0;
  char error[BT_CURL_ERROR_SIZE];
  const char *message = "";
  long status = 0;

  if (!initialized) {
    curl_global_init(BT_CURL_GLOBAL_DEFAULT);
    initialized = 1;
  }
  error[0] = '\0';

  CURL *handle = curl_easy_init();
  if (handle == NULL) {
    message = "curl_easy_init failed";
  } else {
    FILE *out = fopen(String_val(v_out), "wb");
    if (out == NULL) {
      message = "cannot open output file";
    } else {
      /* curl_easy_setopt and curl_slist_append copy their string
         arguments immediately, so OCaml string pointers are safe here */
      struct curl_slist *headers =
        curl_slist_append(NULL, String_val(v_header));
      curl_easy_setopt(handle, BT_CURLOPT_URL, String_val(v_url));
      curl_easy_setopt(handle, BT_CURLOPT_HTTPHEADER, headers);
      curl_easy_setopt(handle, BT_CURLOPT_WRITEDATA, out);
      curl_easy_setopt(handle, BT_CURLOPT_ERRORBUFFER, error);
      curl_easy_setopt(handle, BT_CURLOPT_NOSIGNAL, 1L);
      CURLcode code = curl_easy_perform(handle);
      if (code == 0)
        curl_easy_getinfo(handle, BT_CURLINFO_RESPONSE_CODE, &status);
      else
        message = error[0] != '\0' ? error : curl_easy_strerror(code);
      curl_slist_free_all(headers);
      fclose(out);
    }
    curl_easy_cleanup(handle);
  }

  result = caml_alloc_tuple(2);
  Store_field(result, 0, Val_long(status));
  Store_field(result, 1, caml_copy_string(message));
  CAMLreturn(result);
}
