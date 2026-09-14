# SPDX-License-Identifier: GPL-3.0-or-later
"""Checked transformations of the pinned, archived protocol (never the vendor tree)."""
from pathlib import Path
import sys

root = Path(sys.argv[1]).resolve()
if root.name != "protocol" or root.parent.name != "native" or root.parent.parent.name != "build":
    raise SystemExit("Only build/native/protocol may be patched")


def change(file, before, after, count=1):
    path = root / "lib" / file
    text = path.read_text(encoding="utf-8")
    if text.count(before) != count:
        raise SystemExit(f"Pinned source mismatch: {file}: {before[:80]!r}")
    path.write_text(text.replace(before, after), encoding="utf-8", newline="\n")


# Identity creation/storage belongs to the host's checked Windows private file
# implementation; low-level signing and crypto remain the licensed protocol.
path = root / "lib" / "crypto.c"
text = path.read_text()
start = text.index("ed25519_key_t *ed25519_key_generate(")
end = text.index("\ned25519_key_t *ed25519_key_from_raw", start)
text = text[:start] + """extern EVP_PKEY *mm_protocol_load_identity(const char *keyfile);

ed25519_key_t *ed25519_key_generate(const char *device_id, const char *keyfile, int *result) {
    *result = 0;
    ed25519_key_t *key = calloc(1, sizeof(*key));
    if (!key) return NULL;
    key->pkey = mm_protocol_load_identity(keyfile);
    if (!key->pkey) { free(key); return NULL; }
    return key;
}
""" + text[end:]
path.write_text(text, encoding="utf-8", newline="\n")
change("pairing.c", "    pairing->ed = ed25519_key_generate(device_id, keyfile, result);",
       "    pairing->ed = ed25519_key_generate(device_id, keyfile, result);\n"
       "    if (!pairing->ed) { free(pairing); return NULL; }")

# Always join producers even when they already exited on EOF/error.
for file, obj in [("httpd.c", "httpd"), ("raop_rtp.c", "raop_rtp"),
                  ("raop_ntp.c", "raop_ntp"), ("raop_rtp_mirror.c", "raop_rtp_mirror")]:
    change(file, f"if (!{obj}->running || {obj}->joined)", f"if ({obj}->joined)")

change("httpd.c", "    /* Initial status joined */",
       "    MUTEX_CREATE(httpd->run_mutex);\n"
       "    httpd->server_fd4 = httpd->server_fd6 = -1;\n\n    /* Initial status joined */")
change("httpd.c", "        free(httpd->connections);",
       "        MUTEX_DESTROY(httpd->run_mutex);\n        free(httpd->connections);")
change("httpd.c", "    char buffer[1024];", "    char buffer[1025];")
change("httpd.c", "        tv.tv_sec = 1;\n        tv.tv_usec = 5000;",
       "        tv.tv_sec = 0;\n        tv.tv_usec = 50000;")
change("httpd.c", "    local_saddrlen = sizeof(local_saddr);",
       "    DWORD io_timeout = 250;\n"
       "    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, (char *)&io_timeout, sizeof(io_timeout));\n"
       "    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, (char *)&io_timeout, sizeof(io_timeout));\n"
       "    local_saddrlen = sizeof(local_saddr);")
# No reverse HTTP/HLS is served. A single receive, feeding the incremental parser,
# avoids hanging on a peer that sends 1-7 bytes and never completes the request.
path = root / "lib" / "httpd.c"
text = path.read_text()
start = text.index("            /* reverse-http responses")
end = text.index("            /* Parse HTTP request", start)
text = text[:start] + """            int ret = recv(connection->socket_fd, buffer, sizeof(buffer) - 1, 0);
            if (ret <= 0) {
                httpd_remove_connection(httpd, connection, 0);
                continue;
            }
            recv_datalen = ret;
""" + text[end:]
path.write_text(text, encoding="utf-8", newline="\n")
change("httpd.c", "                        if (ret == -1) {", "                        if (ret <= 0) {")
# Only the HTTP owner touches connection arrays or destroys protocol sessions.
change("httpd.h", "    void  (*conn_destroy)(void *ptr);",
       "    void  (*conn_destroy)(void *ptr);\n    int (*conn_should_close)(void *ptr);")
change("httpd.h", "void httpd_remove_known_connections(httpd_t *httpd);",
       "void httpd_remove_known_connections(httpd_t *httpd);\n"
       "void httpd_remove_other_connections(httpd_t *httpd, void *keep);")
change("httpd.c", "static int\nhttpd_add_connection", """void httpd_remove_other_connections(httpd_t *httpd, void *keep) {
    for (int i = 0; i < httpd->max_connections; ++i) {
        http_connection_t *connection = &httpd->connections[i];
        if (connection->connected && connection->user_data != keep &&
            connection->type == CONNECTION_TYPE_RAOP)
            httpd_remove_connection(httpd, connection, 0);
    }
}

static int
httpd_add_connection""")
change("httpd.c", "            if (httpd->connections[i].pending_remove) {",
       "            if (httpd->callbacks.conn_should_close &&\n"
       "                httpd->callbacks.conn_should_close(httpd->connections[i].user_data))\n"
       "                httpd->connections[i].pending_remove = 1;\n"
       "            if (httpd->connections[i].pending_remove) {")
# Newest-wins teardown happens on the HTTP thread before admitting a new session,
# so old producer callbacks cannot run after the replacement's start.
change("httpd.c", "        connection->pending_remove = 1;\n    }\n}",
       "        httpd_remove_connection(httpd, connection, 0);\n    }\n}", count=2)
change("httpd.c", "    running = httpd->running || !httpd->joined;", "    running = httpd->running;")
change("httpd.c", "    THREAD_CREATE(httpd->thread, httpd_thread, httpd);",
       "    THREAD_CREATE(httpd->thread, httpd_thread, httpd);\n"
       "    if (!httpd->thread) {\n"
       "        httpd->running = 0; httpd->joined = 1;\n"
       "        CLOSESOCKET(httpd->server_fd4); CLOSESOCKET(httpd->server_fd6);\n"
       "        httpd->server_fd4 = httpd->server_fd6 = -1;\n"
       "        MUTEX_UNLOCK(httpd->run_mutex); return -3;\n    }")

# Identity-scoped teardown command. No raw socket count is app session state.
change("raop.c", "struct raop_s {", """extern void mm_protocol_session(void *, uint64_t, int);

struct raop_s {
    volatile LONG64 disconnect_session;
    uint64_t next_session;
""")
change("raop.c", "struct raop_conn_s {", "struct raop_conn_s {\n    uint64_t session_id;")
change("raop.c", '#include "raop_handlers.h"', """void mm_protocol_disconnect(raop_t *raop, uint64_t session_id) {
    InterlockedExchange64(&raop->disconnect_session, (LONG64) session_id);
}

static int conn_should_close(void *ptr) {
    raop_conn_t *conn = ptr;
    return conn->session_id && conn->session_id ==
        (uint64_t) InterlockedCompareExchange64(&conn->raop->disconnect_session, 0, 0);
}

static bool other_active_session(raop_conn_t *conn) {
    int count = httpd_count_connection_type(conn->raop->httpd, CONNECTION_TYPE_RAOP);
    for (int i = 1; i <= count; ++i) {
        raop_conn_t *other = httpd_get_connection_by_type(conn->raop->httpd, CONNECTION_TYPE_RAOP, i);
        if (other && other != conn && other->session_id) return true;
    }
    return false;
}

#include "raop_handlers.h" """)
path = root / "lib" / "raop.c"
text = path.read_text()
start = text.index("            if (httpd_count_connection_type(raop->httpd, CONNECTION_TYPE_RAOP)) {")
end = text.index('            logger_log(raop->logger, LOGGER_DEBUG, "New connection %p identified as Connection type RAOP"', start)
text = text[:start] + text[end:]
path.write_text(text, encoding="utf-8", newline="\n")
change("raop.c", "    httpd_cbs.conn_destroy = &conn_destroy;",
       "    httpd_cbs.conn_destroy = &conn_destroy;\n    httpd_cbs.conn_should_close = &conn_should_close;")
change("raop.c", "    if (raop->callbacks.video_flush) {\n"
       "        raop->callbacks.video_flush(raop->callbacks.cls);\n    }",
       "    if (conn->session_id) mm_protocol_session(raop->callbacks.cls, conn->session_id, 3);")
change("raop.c", "        raop_stop_httpd(raop);", "        if (raop->httpd) raop_stop_httpd(raop);")
# A disabled HLS endpoint returns an explicit response; it never fetches a URL.
change("raop.c", '    if (!cseq && !raop->hls_support && !ble) {',
       '    if (!strcmp(protocol, "HTTP/1.1") || (!cseq && !raop->hls_support && !ble)) {')
change("raop.c", '        logger_log(raop->logger, LOGGER_INFO, "ignoring AirPlay video streaming request (use option -hls to activate HLS support)");',
       '        *response = http_response_create();\n'
       '        http_response_init(*response, protocol, 501, "Unsupported Content");\n'
       '        http_response_finish(*response, NULL, 0);')
change("raop.c", '        http_response_init(*response, protocol, 431, "Request Header Fields Too Large");',
       '        http_response_init(*response, protocol, 431, "Request Header Fields Too Large");\n'
       '        http_response_finish(*response, NULL, 0);')

# Reject malformed binary plist envelopes and fixed-size key fields before any
# low-level compatibility handler reads them.
change("raop.c", "    if (handler != NULL) {\n        handler(", """    if (handler != NULL) {
        const char *type = http_request_get_header(request, "Content-Type");
        if (type && strstr(type, "apple-binary-plist")) {
            int size = 0;
            const char *body = http_request_get_data(request, &size);
            plist_t check = NULL;
            if (body && size > 0) plist_from_bin(body, size, &check);
            bool valid = PLIST_IS_DICT(check);
            const char *fields[] = {"eiv", "ekey"};
            const uint64_t sizes[] = {16, 72};
            for (int i = 0; valid && i < 2; i++) {
                plist_t value = plist_dict_get_item(check, fields[i]);
                if (!value) continue;
                uint64_t length = 0;
                if (PLIST_IS_DATA(value)) plist_get_data_ptr(value, &length);
                valid = length == sizes[i];
            }
            plist_free(check);
            if (!valid) {
                http_response_init(*response, protocol, 400, "Invalid Request");
                goto finish;
            }
        }
        handler(""")
# The callback's opaque session id is not a device identifier or pairing secret.
change("raop_handlers.h",
       "                    raop_rtp_mirror_start(conn->raop_rtp_mirror, &dport, raop->clientFPSdata);",
       "                    raop_rtp_mirror_set_session_id(conn->raop_rtp_mirror, conn->session_id);\n"
       "                    raop_rtp_mirror_start(conn->raop_rtp_mirror, &dport, raop->clientFPSdata);")
change("raop_handlers.h", "    if (PLIST_IS_DATA(req_eiv_node) && PLIST_IS_DATA(req_ekey_node)) {",
       "    if (PLIST_IS_DATA(req_eiv_node) && PLIST_IS_DATA(req_ekey_node)) {\n"
       "        if (conn->session_id || (!httpd_nohold(raop->httpd) && other_active_session(conn))) {\n"
       "            http_response_init(response, \"RTSP/1.0\", 409, \"Session Already Negotiated\");\n"
       "            plist_free(req_root_node); plist_free(res_root_node); return;\n        }")
change("raop_handlers.h", "        conn->raop_ntp = raop_ntp_init",
       "        httpd_remove_other_connections(raop->httpd, conn);\n"
       "        conn->session_id = ++raop->next_session;\n"
       "        mm_protocol_session(raop->callbacks.cls, conn->session_id, 1);\n"
       "        conn->raop_ntp = raop_ntp_init")
change("raop_handlers.h",
       "        int ret = fairplay_decrypt(conn->fairplay, (unsigned char*) eaeskey, aeskey);",
       "        int ret = fairplay_decrypt(conn->fairplay, (unsigned char*) eaeskey, aeskey);\n"
       "        if (ret < 0) {\n"
       "            http_response_init(response, \"RTSP/1.0\", 403, \"Key Negotiation Required\");\n"
       "            http_response_set_disconnect(response, 1);\n"
       "            plist_free(req_root_node); plist_free(res_root_node); return;\n        }")
change("raop_handlers.h", "        raop_ntp_start(conn->raop_ntp, &timing_lport);",
       "        if (!conn->raop_ntp) {\n"
       "            http_response_init(response, \"RTSP/1.0\", 500, \"Session Initialization Failed\");\n"
       "            http_response_set_disconnect(response, 1);\n"
       "            plist_free(req_root_node); plist_free(res_root_node); return;\n        }\n"
       "        raop_ntp_start(conn->raop_ntp, &timing_lport);")
change("raop_rtp_mirror.h", "#endif",
       "void raop_rtp_mirror_set_session_id(raop_rtp_mirror_t *, uint64_t);\n\n#endif")
change("raop_rtp_mirror.c", "struct raop_rtp_mirror_s {",
       "extern void mm_protocol_session(void *, uint64_t, int);\n\n"
       "struct raop_rtp_mirror_s {\n    uint64_t session_id;")
change("raop_rtp_mirror.c", "void\nraop_rtp_mirror_init_aes",
       "void raop_rtp_mirror_set_session_id(raop_rtp_mirror_t *mirror, uint64_t id) {\n"
       "    mirror->session_id = id;\n}\n\nvoid\nraop_rtp_mirror_init_aes")
change("raop_rtp_mirror.c", "            struct timeval tv;\n            tv.tv_sec = 0;\n            tv.tv_usec = 5000;",
       "            DWORD tv = 50;")
change("raop_rtp_mirror.c",
       "sock_err == SOCKET_ERRORNAME(EAGAIN) || sock_err == SOCKET_ERRORNAME(EWOULDBLOCK)",
       "sock_err == WSAETIMEDOUT || sock_err == SOCKET_ERRORNAME(EAGAIN) || sock_err == SOCKET_ERRORNAME(EWOULDBLOCK)",
       count=2)
change("raop_rtp_mirror.c", "                FD_CLR(stream_fd, &rfds);\n                stream_fd = -1;\n                continue;",
       "                break;")
change("raop_rtp_mirror.c", "            int payload_size = byteutils_get_int(packet, 0);",
       """            uint32_t wire_size = (uint32_t) packet[0] | ((uint32_t) packet[1] << 8) |
                ((uint32_t) packet[2] << 16) | ((uint32_t) packet[3] << 24);
            if (wire_size > MM_MIRROR_MAX_PAYLOAD ||
                (packet[4] == 0 && wire_size < 5)) break;
            int payload_size = (int) wire_size;""")
change("raop_rtp_mirror.c", "            switch (packet[4]) {",
       "            if (packet[4] == 0 && payload_size < 5) break;\n"
       "            bool state_only = packet[4] == 1 && payload_size == 0 &&\n"
       "                (packet[6] == 0x56 || packet[6] == 0x5e ||\n"
       "                 (video_stream_suspended && (packet[6] == 0x16 || packet[6] == 0x1e)));\n"
       "            if (packet[4] == 1 && !state_only && !mm_valid_codec_payload(payload, payload_size)) break;\n"
       "            switch (packet[4]) {")
change("raop_rtp_mirror.c", "                assert (raop_rtp_mirror->callbacks.video_set_codec);",
       "                if (state_only) break;\n"
       "                assert (raop_rtp_mirror->callbacks.video_set_codec);")
change("raop_rtp_mirror.c",
       "                raop_rtp_mirror->callbacks.video_process(raop_rtp_mirror->callbacks.cls, raop_rtp_mirror->ntp, &video_data);",
       "                if (valid_data && video_stream_suspended) {\n"
       "                    raop_rtp_mirror->callbacks.video_resume(raop_rtp_mirror->callbacks.cls);\n"
       "                    video_stream_suspended = false;\n"
       "                }\n"
       "                raop_rtp_mirror->callbacks.video_process(raop_rtp_mirror->callbacks.cls, raop_rtp_mirror->ntp, &video_data);")
change("raop_rtp_mirror.c", "#define RAOP_PACKET_LEN 32768", """#define MM_MIRROR_MAX_PAYLOAD (8U * 1024U * 1024U)
#define MM_MIRROR_PACKET_TIMEOUT_MS 2000

static bool mm_mirror_read_allowed(raop_rtp_mirror_t *mirror, ULONGLONG deadline) {
    MUTEX_LOCK(mirror->run_mutex);
    bool running = mirror->running != 0;
    MUTEX_UNLOCK(mirror->run_mutex);
    return running && (!deadline || GetTickCount64() < deadline);
}

static bool mm_valid_codec_payload(const unsigned char *data, int size) {
    if (!data || size < 11) return false;
    if (!memcmp(data + 4, "hvc1", 4)) {
        size_t offset = 0x75;
        for (unsigned int kind = 0xa0; kind <= 0xa2; kind++) {
            if (offset + 5 > (size_t) size || data[offset] != kind ||
                data[offset + 1] != 0 || data[offset + 2] != 1) return false;
            unsigned int length = ((unsigned int) data[offset + 3] << 8) | data[offset + 4];
            if (!length || length > 32767 || offset + 5 + length > (size_t) size) return false;
            offset += 5 + length;
        }
        return true;
    }
    unsigned int sps = ((unsigned int) data[6] << 8) | data[7];
    if (!sps || sps > 32767 || 11 + sps > (unsigned int) size) return false;
    unsigned int pps = ((unsigned int) data[sps + 9] << 8) | data[sps + 10];
    return pps && pps <= 32767 && 11 + sps + pps <= (unsigned int) size;
}

#define RAOP_PACKET_LEN 32768""")
change("raop_rtp_mirror.c", "    unsigned int readstart = 0;",
       "    unsigned int readstart = 0;\n    ULONGLONG packet_deadline = 0;")
change("raop_rtp_mirror.c", "        /* Set timeout valu to 5ms */",
       "        if (packet_deadline && GetTickCount64() >= packet_deadline) break;\n"
       "        /* Set timeout valu to 5ms */")
change("raop_rtp_mirror.c", "            while (payload == NULL && readstart < 128) {",
       "            while (payload == NULL && readstart < 128) {\n"
       "                if (!mm_mirror_read_allowed(raop_rtp_mirror, packet_deadline)) { ret = 0; break; }")
change("raop_rtp_mirror.c", "                readstart = readstart + ret;",
       "                if (!packet_deadline) packet_deadline = GetTickCount64() + MM_MIRROR_PACKET_TIMEOUT_MS;\n"
       "                readstart = readstart + ret;", count=2)
change("raop_rtp_mirror.c", "                payload = malloc(payload_size);",
       "                payload = malloc(payload_size ? (size_t) payload_size : 1);\n"
       "                if (!payload) break;")
change("raop_rtp_mirror.c", "            while ((int) readstart < payload_size) {",
       "            while ((int) readstart < payload_size) {\n"
       "                if (!mm_mirror_read_allowed(raop_rtp_mirror, packet_deadline)) { ret = 0; break; }")
change("raop_rtp_mirror.c", "            readstart = 0;\n            if (unsupported_codec",
       "            readstart = 0;\n            packet_deadline = 0;\n            if (unsupported_codec")
change("raop_rtp_mirror.c", "                if (prepend_sps_pps) {\n                    assert(sps_pps);",
       "                if (prepend_sps_pps) {\n"
       "                    if (!sps_pps || sps_pps_len <= 0 ||\n"
       "                        (unsigned int) sps_pps_len > MM_MIRROR_MAX_PAYLOAD ||\n"
       "                        (unsigned int) payload_size > MM_MIRROR_MAX_PAYLOAD - (unsigned int) sps_pps_len) {\n"
       "                        conn_reset = true; break;\n                    }")
change("raop_rtp_mirror.c", '                        printf("Memory allocation failed (payload_out)\\n");\n'
       "                        exit(1);", "                        conn_reset = true; break;")
change("raop_rtp_mirror.c", "                    payload_out = (unsigned char*)  malloc(payload_size);",
       "                    payload_out = (unsigned char*) malloc(payload_size);\n"
       "                    if (!payload_out) { conn_reset = true; break; }")
change("raop_rtp_mirror.c", "                    sps_pps = (unsigned char*) malloc(sps_pps_len);\n"
       "                    assert(sps_pps);",
       "                    free(sps_pps);\n"
       "                    sps_pps = (unsigned char*) malloc(sps_pps_len);\n"
       "                    if (!sps_pps) { conn_reset = true; break; }", count=2)
change("raop_rtp_mirror.c", "                    int nc_len = byteutils_get_int_be(payload_decrypted, nalu_size);",
       "                    if (payload_size - nalu_size < 5) { valid_data = false; break; }\n"
       "                    int nc_len = byteutils_get_int_be(payload_decrypted, nalu_size);")
change("raop_rtp_mirror.c", "                    if (nc_len < 0 || nalu_size + 4 > payload_size) {",
       "                    if (nc_len <= 0 || nc_len > payload_size - nalu_size - 4) {")
change("raop_rtp_mirror.c", "    /* Close the stream file descriptor */",
       "    free(payload);\n    free(sps_pps);\n    /* Close the stream file descriptor */")
change("raop_rtp_mirror.c", "    if (unsupported_codec) {\n"
       "        CLOSESOCKET(raop_rtp_mirror->mirror_data_sock);\n"
       "        raop_rtp_mirror_stop(raop_rtp_mirror);\n"
       "        raop_rtp_mirror->callbacks.video_reset(raop_rtp_mirror->callbacks.cls, RESET_TYPE_RTP_SHUTDOWN);\n    }",
       "    mm_protocol_session(raop_rtp_mirror->callbacks.cls, raop_rtp_mirror->session_id, 2);")
change("raop_rtp_mirror.c", "            if (unsupported_codec) {",
       "            if (unsupported_codec || conn_reset) {")
change("raop_rtp_mirror.c", "    THREAD_CREATE(raop_rtp_mirror->thread_mirror, raop_rtp_mirror_thread, raop_rtp_mirror);",
       "    THREAD_CREATE(raop_rtp_mirror->thread_mirror, raop_rtp_mirror_thread, raop_rtp_mirror);\n"
       "    if (!raop_rtp_mirror->thread_mirror) {\n"
       "        raop_rtp_mirror->running = 0; raop_rtp_mirror->joined = 1;\n"
       "        CLOSESOCKET(raop_rtp_mirror->mirror_data_sock);\n"
       "        raop_rtp_mirror->mirror_data_sock = -1;\n"
       "        mm_protocol_session(raop_rtp_mirror->callbacks.cls, raop_rtp_mirror->session_id, 2);\n    }")

# llhttp owns the parsed protocol/version. The upstream on_url copy can read
# beyond a fragmented receive buffer; derive RTSP/HTTP at message completion.
change("http_request.c", "    strncpy(request->protocol, at + length + 1, 8);", "")
change("http_request.c", "    request->complete = 1;",
       '    snprintf(request->protocol + 4, sizeof(request->protocol) - 4, "/%u.%u",\n'
       '        request->parser.http_major, request->parser.http_minor);\n'
       "    request->complete = 1;")
change("http_request.c", "static int\non_url", """static int
on_protocol(llhttp_t *parser, const char *at, size_t length) {
    http_request_t *request = parser->data;
    size_t used = strlen(request->protocol);
    if (used + length > 4) return HPE_USER;
    memcpy(request->protocol + used, at, length);
    return 0;
}

static int
on_url""")
change("http_request.c", "    request->parser_settings.on_url = &on_url;",
       "    request->parser_settings.on_url = &on_url;\n"
       "    request->parser_settings.on_protocol = &on_protocol;")
change("http_request.c", "struct http_request_s {",
       "#define MM_HTTP_MAX_BODY (1024U * 1024U)\n"
       "#define MM_HTTP_MAX_HEADERS 16384U\n"
       "#define MM_HTTP_MAX_HEADER_PAIRS 64\n\nstruct http_request_s {")
change("http_request.c", "    int complete;",
       "    int complete;\n    size_t total_bytes;\n    size_t header_bytes;")
path = root / "lib" / "http_request.c"
text = path.read_text()
start = text.index("static int\non_url")
end = text.index("static int\non_message_complete", start)
text = text[:start] + """/* MirrorMe receive limits apply before every variable-size allocation. */
static int append_bounded(char **target, size_t limit, const char *at, size_t length) {
    size_t used = *target ? strlen(*target) : 0;
    if (used > limit || length > limit - used) return HPE_USER;
    char *next = realloc(*target, used + length + 1);
    if (!next) return HPE_USER;
    memcpy(next + used, at, length);
    next[used + length] = '\\0';
    *target = next;
    return 0;
}

static int
on_url(llhttp_t *parser, const char *at, size_t length) {
    http_request_t *request = parser->data;
    return append_bounded(&request->url, 2048, at, length);
}

static int
on_header_field(llhttp_t *parser, const char *at, size_t length) {
    http_request_t *request = parser->data;
    if (length > MM_HTTP_MAX_HEADERS - request->header_bytes) return HPE_USER;
    if (request->headers_index % 2 == 1) request->headers_index++;
    if (request->headers_index == request->headers_size) {
        if (request->headers_size >= 2 * MM_HTTP_MAX_HEADER_PAIRS) return HPE_USER;
        char **next = realloc(request->headers, (request->headers_size + 2) * sizeof(*next));
        if (!next) return HPE_USER;
        request->headers = next;
        request->headers[request->headers_size++] = NULL;
        request->headers[request->headers_size++] = NULL;
    }
    int result = append_bounded(&request->headers[request->headers_index], MM_HTTP_MAX_HEADERS, at, length);
    if (!result) request->header_bytes += length;
    return result;
}

static int
on_header_value(llhttp_t *parser, const char *at, size_t length) {
    http_request_t *request = parser->data;
    if (length > MM_HTTP_MAX_HEADERS - request->header_bytes) return HPE_USER;
    if (request->headers_index % 2 == 0) request->headers_index++;
    int result = append_bounded(&request->headers[request->headers_index], MM_HTTP_MAX_HEADERS, at, length);
    if (!result) request->header_bytes += length;
    return result;
}

static int
on_headers_complete(llhttp_t *parser) {
    return parser->content_length > MM_HTTP_MAX_BODY ? HPE_USER : 0;
}

static int
on_chunk_header(llhttp_t *parser) {
    http_request_t *request = parser->data;
    return parser->content_length > MM_HTTP_MAX_BODY - (size_t) request->datalen ? HPE_USER : 0;
}

static int
on_body(llhttp_t *parser, const char *at, size_t length) {
    http_request_t *request = parser->data;
    if (length > MM_HTTP_MAX_BODY - (size_t) request->datalen) return HPE_USER;
    if (!length) return 0;
    char *next = realloc(request->data, (size_t) request->datalen + length);
    if (!next) return HPE_USER;
    request->data = next;
    memcpy(request->data + request->datalen, at, length);
    request->datalen += (int) length;
    return 0;
}

""" + text[end:]
path.write_text(text, encoding="utf-8", newline="\n")
change("http_request.c", "    request->parser_settings.on_body = &on_body;",
       "    request->parser_settings.on_body = &on_body;\n"
       "    request->parser_settings.on_headers_complete = &on_headers_complete;\n"
       "    request->parser_settings.on_chunk_header = &on_chunk_header;")
change("http_request.c", "    int ret = llhttp_execute(&request->parser, data, datalen);",
       "    if (datalen < 0 || (size_t) datalen > MM_HTTP_MAX_BODY + MM_HTTP_MAX_HEADERS - request->total_bytes) {\n"
       "        request->parser.error = HPE_USER;\n"
       '        llhttp_set_error_reason(&request->parser, "Request exceeds supported wire limit");\n'
       "        return HPE_USER;\n    }\n"
       "    request->total_bytes += (size_t) datalen;\n"
       "    int ret = llhttp_execute(&request->parser, data, datalen);")
change("httpd.c", "                assert(connection->request);",
       "                if (!connection->request) {\n"
       "                    httpd_remove_connection(httpd, connection, 0); continue;\n                }")
print("Applied checked MirrorMe protocol lifecycle and Windows transport patches.")
