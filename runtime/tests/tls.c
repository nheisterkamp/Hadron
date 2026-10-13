/* Fetches an HTTPS page through WinHTTP, which goes through schannel and so through
 * the runtime's GnuTLS. Any HTTP status means the TLS handshake worked. */
#include <windows.h>
#include <winhttp.h>
#include <stdio.h>

int main(void)
{
    HINTERNET session, connection, request;
    DWORD status = 0, size = sizeof(status);

    session = WinHttpOpen(L"hadron-tls-check", WINHTTP_ACCESS_TYPE_DEFAULT_PROXY,
                          WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
    connection = session ? WinHttpConnect(session, L"example.com", INTERNET_DEFAULT_HTTPS_PORT, 0) : NULL;
    request = connection ? WinHttpOpenRequest(connection, L"GET", L"/", NULL, WINHTTP_NO_REFERER,
                                              WINHTTP_DEFAULT_ACCEPT_TYPES, WINHTTP_FLAG_SECURE) : NULL;
    if (!request || !WinHttpSendRequest(request, WINHTTP_NO_ADDITIONAL_HEADERS, 0, NULL, 0, 0, 0)
        || !WinHttpReceiveResponse(request, NULL)
        || !WinHttpQueryHeaders(request, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
                                NULL, &status, &size, NULL))
    {
        printf("FAIL: HTTPS request failed, error %lu\n", GetLastError());
        return 1;
    }
    printf("HTTPS status %lu\n", status);
    return 0;
}
