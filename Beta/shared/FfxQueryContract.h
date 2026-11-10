#pragma once
#include <ffx_api.h>
namespace optishade::ffx {
// A provider-version query contains OUTPUT fields, not an effect descriptor.
inline ffxStructType_t QueryType(const ffxQueryDescHeader* header) {
    if (!header) return 0;
    if (header->type == FFX_API_QUERY_DESC_TYPE_GET_VERSIONS)
        return static_cast<const ffxQueryDescGetVersions*>(static_cast<const void*>(header))->createDescType;
    return header->type;
}
inline ffxReturnCode_t CreationResult(ffxReturnCode_t result, ffxContext context) {
    if (result != FFX_API_RETURN_OK) return result;
    return context ? FFX_API_RETURN_OK : FFX_API_RETURN_ERROR_RUNTIME_ERROR;
}
}
