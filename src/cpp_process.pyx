# distutils: language=c++
# cython: language_level=3
# cython: binding=True

from rapidfuzz.utils import default_process

from rapidfuzz.string_metric import (
    levenshtein,
    normalized_levenshtein,
    hamming,
    normalized_hamming
)

from rapidfuzz.fuzz import (
    ratio,
    partial_ratio,
    token_sort_ratio,
    token_set_ratio,
    token_ratio,
    partial_token_sort_ratio,
    partial_token_set_ratio,
    partial_token_ratio,
    QRatio,
    WRatio
)

from libcpp.vector cimport vector
from libcpp cimport algorithm

from cpython.list cimport PyList_New
from cpython.list cimport PyList_SET_ITEM
from cpython.object cimport PyObject
from cpython.ref cimport Py_INCREF
from cpython.ref cimport Py_DECREF

import heapq

cdef extern from "Python.h":
    # This isn't included in the cpython definitions
    # using PyObject* rather than object lets us control refcounting
    PyObject* Py_BuildValue(const char*,...) except NULL


cdef extern from "cpp_process.hpp":
    ctypedef double (*scorer_func) (void* context, object py_str, double score_cutoff) except +
    ctypedef size_t (*distance_func) (void* context, object py_str, size_t max) except +
    ctypedef void (*context_deinit) (void* context) except +

    ctypedef struct scorer_context:
        void* context
        scorer_func scorer
        context_deinit deinit

    ctypedef struct distance_context:
        void* context
        distance_func scorer
        context_deinit deinit

    # normalized distances
    # fuzz
    scorer_context cached_ratio_init(                   object, int) except +
    scorer_context cached_partial_ratio_init(           object, int) except +
    scorer_context cached_token_sort_ratio_init(        object, int) except +
    scorer_context cached_token_set_ratio_init(         object, int) except +
    scorer_context cached_token_ratio_init(             object, int) except +
    scorer_context cached_partial_token_sort_ratio_init(object, int) except +
    scorer_context cached_partial_token_set_ratio_init( object, int) except +
    scorer_context cached_partial_token_ratio_init(     object, int) except +
    scorer_context cached_WRatio_init(                  object, int) except +
    scorer_context cached_QRatio_init(                  object, int) except +
    # string_metric
    scorer_context cached_normalized_levenshtein_init(object, int, size_t, size_t, size_t) except +
    scorer_context cached_normalized_hamming_init(    object, int) except +

    # distances
    distance_context cached_levenshtein_init(object, int, size_t, size_t, size_t) except +
    distance_context cached_hamming_init(    object, int) except +


    ctypedef struct ExtractScorerComp:
        pass

    ctypedef struct ListMatchScorerElem:
        double score
        size_t index

    ctypedef struct DictMatchScorerElem:
        double score
        size_t index
        PyObject* choice
        PyObject* key

    ctypedef struct ExtractDistanceComp:
        pass

    ctypedef struct ListMatchDistanceElem:
        size_t distance
        size_t index

    ctypedef struct DictMatchDistanceElem:
        size_t distance
        size_t index
        PyObject* choice
        PyObject* key


cdef inline extractOne_dict(scorer_context context, choices, processor, double score_cutoff):
    """
    implementation of extractOne for:
      - type of choices = dict
      - scorer = normalized scorer implemented in C++
    """
    cdef double score
    # use -1 as score, so even a score of 0 in the first iteration is higher
    cdef double result_score = -1
    result_choice = None
    result_key = None

    if processor is not None:
        for choice_key, choice in choices.items():
            if choice is None:
                continue

            score = context.scorer(context.context, processor(choice), score_cutoff)

            if score >= score_cutoff and score > result_score:
                result_score = score_cutoff = score
                result_choice = choice
                result_key = choice_key

                if result_score == 100:
                    break
    else:
        for choice_key, choice in choices.items():
            if choice is None:
                continue

            score = context.scorer(context.context, choice, score_cutoff)

            if score >= score_cutoff and score > result_score:
                result_score = score_cutoff = score
                result_choice = choice
                result_key = choice_key

                if result_score == 100:
                    break

    return (result_choice, result_score, result_key) if result_choice is not None else None


cdef inline extractOne_distance_dict(distance_context context, choices, processor, size_t max_):
    """
    implementation of extractOne for:
      - type of choices = dict
      - scorer = Distance implemented in C++
    """
    cdef size_t distance
    cdef size_t result_distance = <size_t>-1
    result_choice = None
    result_key = None

    if processor is not None:
        for choice_key, choice in choices.items():
            if choice is None:
                continue

            distance = context.scorer(context.context, processor(choice), max_)

            if distance <= max_ and distance < result_distance:
                result_distance = max_ = distance
                result_choice = choice
                result_key = choice_key

                if result_distance == 0:
                    break
    else:
        for choice_key, choice in choices.items():
            if choice is None:
                continue

            distance = context.scorer(context.context, choice, max_)

            if distance <= max_ and distance < result_distance:
                result_distance = max_ = distance
                result_choice = choice
                result_key = choice_key

                if result_distance == 0:
                    break

    return (result_choice, result_distance, result_key) if result_choice is not None else None


cdef inline extractOne_list(scorer_context context, choices, processor, double score_cutoff):
    """
    implementation of extractOne for:
      - type of choices = list
      - scorer = normalized scorer implemented in C++
    """
    cdef double score = 0.0
    # use -1 as score, so even a score of 0 in the first iteration is higher
    cdef double result_score = -1
    cdef int index = 0
    cdef int result_index = 0
    result_choice = None

    if processor is not None:
        for choice in choices:
            if choice is None:
                index += 1
                continue

            score = context.scorer(context.context, processor(choice), score_cutoff)

            if score >= score_cutoff and score > result_score:
                result_score = score_cutoff = score
                result_choice = choice
                result_index = index

                if result_score == 100:
                    break
            index += 1
    else:
        for choice in choices:
            if choice is None:
                index += 1
                continue

            score = context.scorer(context.context, choice, score_cutoff)

            if score >= score_cutoff and score > result_score:
                result_score = score_cutoff = score
                result_choice = choice
                result_index = index

                if result_score == 100:
                    break
            index += 1

    return (result_choice, result_score, result_index) if result_choice is not None else None


cdef inline extractOne_distance_list(distance_context context, choices, processor, size_t max_):
    """
    implementation of extractOne for:
      - type of choices = list
      - scorer = Distance implemented in C++
    """
    cdef size_t distance
    cdef size_t result_distance = <size_t>-1
    cdef int index = 0
    cdef int result_index = 0
    result_choice = None

    if processor is not None:
        for choice in choices:
            if choice is None:
                index += 1
                continue

            distance = context.scorer(context.context, processor(choice), max_)

            if distance <= max_ and distance < result_distance:
                result_distance = max_ = distance
                result_choice = choice
                result_index = index

                if result_distance == 0:
                    break
            index += 1
    else:
        for choice in choices:
            if choice is None:
                index += 1
                continue

            distance = context.scorer(context.context, choice, max_)

            if distance <= max_ and distance < result_distance:
                result_distance = max_ = distance
                result_choice = choice
                result_index = index

                if result_distance == 0:
                    break
            index += 1

    return (result_choice, result_distance, result_index) if result_choice is not None else None


cdef inline py_extractOne_dict(query, choices, scorer, processor, double score_cutoff, kwargs):
    result_score = 0
    result_choice = None
    result_key = None

    if processor is not None:
        for choice_key, choice in choices.items():
            if choice is None:
                continue

            score = scorer(query, processor(choice),
                processor=None, score_cutoff=score_cutoff, **kwargs)

            if score > result_score:
                score_cutoff = score
                result_score = score
                result_choice = choice
                result_key = choice_key

                if score_cutoff == 100:
                    break
    else:
        for choice_key, choice in choices.items():
            if choice is None:
                continue

            score = scorer(query, choice,
                processor=None, score_cutoff=score_cutoff, **kwargs)

            if score > result_score:
                score_cutoff = score
                result_score = score
                result_choice = choice
                result_key = choice_key

                if score_cutoff == 100:
                    break

    return (result_choice, result_score, result_key) if result_choice is not None else None


cdef inline py_extractOne_list(query, choices, scorer, processor, double score_cutoff, kwargs):
    cdef int result_index = 0
    cdef int index = 0
    result_score = 0
    result_choice = None

    if processor is not None:
        for choice in choices:
            if choice is None:
                index += 1
                continue

            score = scorer(query, processor(choice),
                processor=None, score_cutoff=score_cutoff, **kwargs)

            if score > result_score:
                score_cutoff = score
                result_score = score
                result_choice = choice
                result_index = index

                if score_cutoff == 100:
                    break
            index += 1
    else:
        for choice in choices:
            if choice is None:
                index += 1
                continue

            score = scorer(query, choice,
                processor=None, score_cutoff=score_cutoff, **kwargs)

            if score > result_score:
                score_cutoff = score
                result_score = score
                result_choice = choice
                result_index = index

                if score_cutoff == 100:
                    break
            index += 1

    return (result_choice, result_score, result_index) if result_choice is not None else None


cdef inline scorer_context CachedNormalizedLevenshteinInit(object query, int def_process, dict kwargs):
    cdef size_t insertion, deletion, substitution
    insertion, deletion, substitution = kwargs.get("weights", (1, 1, 1))
    return cached_normalized_levenshtein_init(query, def_process, insertion, deletion, substitution)

cdef inline distance_context CachedLevenshteinInit(object query, int def_process, dict kwargs):
    cdef size_t insertion, deletion, substitution
    insertion, deletion, substitution = kwargs.get("weights", (1, 1, 1))
    return cached_levenshtein_init(query, def_process, insertion, deletion, substitution)


cdef inline scorer_context CachedScorerInit(object scorer, object query, int def_process, dict kwargs):
    cdef scorer_context context

    if scorer is ratio:
        context = cached_ratio_init(query, def_process)
    elif scorer is partial_ratio:
        context = cached_partial_ratio_init(query, def_process)
    elif scorer is token_sort_ratio:
        context = cached_token_sort_ratio_init(query, def_process)
    elif scorer is token_set_ratio:
        context = cached_token_set_ratio_init(query, def_process)
    elif scorer is token_ratio:
        context = cached_token_ratio_init(query, def_process)
    elif scorer is partial_token_sort_ratio:
        context = cached_partial_token_sort_ratio_init(query, def_process)
    elif scorer is partial_token_set_ratio:
        context = cached_partial_token_set_ratio_init(query, def_process)
    elif scorer is partial_token_ratio:
        context = cached_partial_token_ratio_init(query, def_process)
    elif scorer is WRatio:
        context = cached_WRatio_init(query, def_process)
    elif scorer is QRatio:
        context = cached_QRatio_init(query, def_process)
    elif scorer is normalized_levenshtein:
        context = CachedNormalizedLevenshteinInit(query, def_process, kwargs)
    elif scorer is normalized_hamming:
        context = cached_normalized_hamming_init(query, def_process)
    else:
        context.context = NULL
    return context


cdef inline distance_context CachedDistanceInit(object scorer, object query, int def_process, dict kwargs):
    cdef distance_context context

    if scorer is levenshtein:
        context = CachedLevenshteinInit(query, def_process, kwargs)
    elif scorer is hamming:
        context = cached_hamming_init(query, def_process)
    else:
        context.context = NULL
    return context


def extractOne(query, choices, scorer=WRatio, processor=default_process, double score_cutoff=0.0, **kwargs):
    """
    Find the best match in a list of choices. When multiple elements have the same similarity,
    the first element is returned.

    Parameters
    ----------
    query : str
        string we want to find
    choices : Iterable
        list of all strings the query should be compared with or dict with a mapping
        {<result>: <string to compare>}
    scorer : Callable, optional
        Optional callable that is used to calculate the matching score between
        the query and each choice. fuzz.WRatio is used by default
    processor : Callable, optional
        Optional callable that reformats the strings.
        utils.default_process is used by default, which lowercases the strings and trims whitespace
    score_cutoff : float, optional
        Optional argument for a score threshold as a float between 0 and 100.
        Matches with a lower score than this number will be ignored. Default is 0,
        which deactivates this behaviour.
    **kwargs : Any, optional
        any other named parameters are passed to the scorer. This can be used to pass
        e.g. weights to string_metric.levenshtein

    Returns
    -------
    Union[None, Tuple[str, float, Any]]
        If the scorer is one of the normalized scorers provided by RapidFuzz
        (e.g. string_metric.normalized_levenshtein), the best match
        is returned in form of a tuple or None when there is no match with a
        `similarity >= score_cutoff`.
        The Tuple will be in the form `(<choice>, <similarity>, <index of choice>)`
        when `choices` is a list of strings or `(<choice>, <similarity>, <key of choice>)`
        when `choices` is a mapping (e.g. a dict). The similarity is a score between 0 and
        100, with 100 being a perfect match.

    Union[None, Tuple[str, int, Any]]
        If the scorer is one of the distances provided by RapidFuzz
        (e.g. string_metric.levenshtein), the best match
        is returned in form of a tuple or None when there is no match with a
        `distance <= max`.
        The Tuple will be in the form `(<choice>, <distance>, <index of choice>)`
        when `choices` is a list of strings or `(<choice>, <distance>, <key of choice>)`
        when `choices` is a mapping (e.g. a dict). Distance is 0 for a perfect match and
        > 0 for non perfect matches.

    Union[None, Tuple[str, Any, Any]]
        If the scorer is none of the distances provided by RapidFuzz, the best match
        is returned in form of a tuple or None when there is no match with a
        `similarity >= score_cutoff`.
        Right now this does not support a similar behavior with distances. In the future
        this could be extended to support this for custom distance metrics as well.
        The Tuple will be in the form `(<choice>, <similarity>, <index of choice>)`
        when `choices` is a list of strings or `(<choice>, <similarity>, <key of choice>)`
        when `choices` is a mapping (e.g. a dict).

    """

    cdef int def_process = 0
    cdef scorer_context ScorerContext
    cdef distance_context DistanceContext
    cdef size_t max_ = <size_t>-1

    if query is None:
        return None

    # preprocess the query
    if processor is default_process:
        def_process = 1
        # since this call is only performed once it is not very expensive to
        # make it in Python
        query = processor(query)
        processor = None
    elif callable(processor):
        query = processor(query)
    elif processor:
        def_process = 1
        # since this call is only performed once it is not very expensive to
        # make it in Python
        query = default_process(query)
        processor = None
    # query might be e.g. False
    else:
        processor = None

    # directly use the C++ implementation if possible
    # normalized distance implemented in C++
    ScorerContext = CachedScorerInit(scorer, query, def_process, kwargs)
    if ScorerContext.context != NULL:
        try:
            if hasattr(choices, "items"):
                return extractOne_dict(ScorerContext, choices, processor, score_cutoff)
            else:
                return extractOne_list(ScorerContext, choices, processor, score_cutoff)
        finally:
            # part of the context is dynamically allocated, so it has to be freed in any case
            ScorerContext.deinit(ScorerContext.context)
    # distance implemented in C++
    DistanceContext = CachedDistanceInit(scorer, query, def_process, kwargs)
    if DistanceContext.context != NULL:
        try:
            if hasattr(choices, "items"):
                return extractOne_distance_dict(DistanceContext, choices, processor, max_)
            else:
                return extractOne_distance_list(DistanceContext, choices, processor, max_)
        finally:
            # part of the context is dynamically allocated, so it has to be freed in any case
            DistanceContext.deinit(DistanceContext.context)

    # the scorer has to be called through Python
    if hasattr(choices, "items"):
        return py_extractOne_dict(query, choices, scorer, processor, score_cutoff, kwargs)
    else:
        return py_extractOne_list(query, choices, scorer, processor, score_cutoff, kwargs)


cdef inline extract_dict(scorer_context context, choices, processor, size_t limit, double score_cutoff):
    cdef double score = 0.0
    cdef size_t index = 0
    cdef size_t i = 0
    # todo storing 32 Byte per element is a bit wasteful
    # maybe store only key and access the corresponding element when building the list
    cdef vector[DictMatchScorerElem] results
    results.reserve(<size_t>len(choices))
    cdef list result_list

    if processor is not None:
        for choice_key, choice in choices.items():
            if choice is None:
                index += 1
                continue

            score = context.scorer(context.context, processor(choice), score_cutoff)

            if score >= score_cutoff:
                # especially the key object might be created on the fly by e.g. pandas.Dataframe
                # so we need to ensure Python does not deallocate it
                Py_INCREF(choice)
                Py_INCREF(choice_key)
                results.push_back(DictMatchScorerElem(score, i, <PyObject*>choice, <PyObject*>choice_key))
            index += 1
    else:
        for choice_key, choice in choices.items():
            if choice is None:
                index += 1
                continue

            score = context.scorer(context.context, choice, score_cutoff)

            if score >= score_cutoff:
                # especially the key object might be created on the fly by e.g. pandas.Dataframe
                # so we need to ensure Python does not deallocate it
                Py_INCREF(choice)
                Py_INCREF(choice_key)
                results.push_back(DictMatchScorerElem(score, i, <PyObject*>choice, <PyObject*>choice_key))
            index += 1

    # due to score_cutoff not always completely filled
    if limit > results.size():
        limit = results.size()

    if limit >= results.size():
        algorithm.sort(results.begin(), results.end(), ExtractScorerComp())
    else:
        algorithm.partial_sort(results.begin(), results.begin() + <ptrdiff_t>limit, results.end(), ExtractScorerComp())

    # copy elements into Python List
    result_list = PyList_New(<Py_ssize_t>limit)
    for i in range(limit):
        # PyList_SET_ITEM steals a reference
        # the casting is necessary to ensure that Cython doesn't
        # decref the result of Py_BuildValue
        # https://stackoverflow.com/questions/43553763/cythonize-list-of-all-splits-of-a-string/43557675#43557675
        # todo probably faster to create the tuple by hand
        PyList_SET_ITEM(result_list, <Py_ssize_t>i,
            <object>Py_BuildValue("OdO",
                <PyObject*>results[i].choice,
                results[i].score,
                <PyObject*>results[i].key))

    # decref all reference counts
    for i in range(results.size()):
        Py_DECREF(<object>results[i].choice)
        Py_DECREF(<object>results[i].key)

    return result_list


cdef inline extract_distance_dict(distance_context context, choices, processor, size_t limit, size_t max_):
    cdef size_t distance
    cdef size_t index = 0
    cdef size_t i = 0
    # todo storing 32 Byte per element is a bit wasteful
    # maybe store only key and access the corresponding element when building the list
    cdef vector[DictMatchDistanceElem] results
    results.reserve(<size_t>len(choices))
    cdef list result_list

    if processor is not None:
        for choice_key, choice in choices.items():
            if choice is None:
                index += 1
                continue

            distance = context.scorer(context.context, processor(choice), max_)

            if distance <= max_:
                # especially the key object might be created on the fly by e.g. pandas.Dataframe
                # so we need to ensure Python does not deallocate it
                Py_INCREF(choice)
                Py_INCREF(choice_key)
                results.push_back(DictMatchDistanceElem(distance, i, <PyObject*>choice, <PyObject*>choice_key))
            index += 1
    else:
        for choice_key, choice in choices.items():
            if choice is None:
                index += 1
                continue

            distance = context.scorer(context.context, choice, max_)

            if distance <= max_:
                # especially the key object might be created on the fly by e.g. pandas.Dataframe
                # so we need to ensure Python does not deallocate it
                Py_INCREF(choice)
                Py_INCREF(choice_key)
                results.push_back(DictMatchDistanceElem(distance, i, <PyObject*>choice, <PyObject*>choice_key))
            index += 1

    # due to max_ not always completely filled
    if limit > results.size():
        limit = results.size()

    if limit >= results.size():
        algorithm.sort(results.begin(), results.end(), ExtractDistanceComp())
    else:
        algorithm.partial_sort(results.begin(), results.begin() + <ptrdiff_t>limit, results.end(), ExtractDistanceComp())

    # copy elements into Python List
    result_list = PyList_New(<Py_ssize_t>limit)
    for i in range(limit):
        # PyList_SET_ITEM steals a reference
        # the casting is necessary to ensure that Cython doesn't
        # decref the result of Py_BuildValue
        # https://stackoverflow.com/questions/43553763/cythonize-list-of-all-splits-of-a-string/43557675#43557675
        # todo probably faster to create the tuple by hand
        PyList_SET_ITEM(result_list, <Py_ssize_t>i,
            <object>Py_BuildValue("OnO",
                <PyObject*>results[i].choice,
                results[i].distance,
                <PyObject*>results[i].key))

    # decref all reference counts
    for i in range(results.size()):
        Py_DECREF(<object>results[i].choice)
        Py_DECREF(<object>results[i].key)

    return result_list


cdef inline extract_list(scorer_context context, choices, processor, size_t limit, double score_cutoff):
    cdef double score = 0.0
    cdef size_t index = 0
    cdef size_t i = 0
    # todo possibly a smaller vector would be good to reduce memory usage
    cdef vector[ListMatchScorerElem] results
    results.reserve(<size_t>len(choices))
    cdef list result_list

    if processor is not None:
        for choice in choices:
            if choice is None:
                index += 1
                continue

            score = context.scorer(context.context, processor(choice), score_cutoff)

            if score >= score_cutoff:
                results.push_back(ListMatchScorerElem(score, index))
            index += 1
    else:
        for choice in choices:
            if choice is None:
                index += 1
                continue

            score = context.scorer(context.context, choice, score_cutoff)

            if score >= score_cutoff:
                results.push_back(ListMatchScorerElem(score, index))
            index += 1

    # due to score_cutoff not always completely filled
    if limit > results.size():
        limit = results.size()

    if limit >= results.size():
        algorithm.sort(results.begin(), results.end(), ExtractScorerComp())
    else:
        algorithm.partial_sort(results.begin(), results.begin() + <ptrdiff_t>limit, results.end(), ExtractScorerComp())

    # copy elements into Python List
    result_list = PyList_New(<Py_ssize_t>limit)
    for i in range(limit):
        # PyList_SET_ITEM steals a reference
        # the casting is necessary to ensure that Cython doesn't
        # decref the result of Py_BuildValue
        # https://stackoverflow.com/questions/43553763/cythonize-list-of-all-splits-of-a-string/43557675#43557675
        # todo probably faster to create the tuple by hand

        PyList_SET_ITEM(result_list, <Py_ssize_t>i,
            <object>Py_BuildValue("Odn",
                <PyObject*>choices[results[i].index],
                results[i].score,
                results[i].index))

    return result_list


cdef inline extract_distance_list(distance_context context, choices, processor, size_t limit, size_t max_):
    cdef size_t distance
    cdef size_t index = 0
    cdef size_t i = 0
    # todo possibly a smaller vector would be good to reduce memory usage
    cdef vector[ListMatchDistanceElem] results
    results.reserve(<size_t>len(choices))
    cdef list result_list

    if processor is not None:
        for choice in choices:
            if choice is None:
                index += 1
                continue

            distance = context.scorer(context.context, processor(choice), max_)

            if distance <= max_:
                results.push_back(ListMatchDistanceElem(distance, index))
            index += 1
    else:
        for choice in choices:
            if choice is None:
                index += 1
                continue

            distance = context.scorer(context.context, choice, max_)

            if distance <= max_:
                results.push_back(ListMatchDistanceElem(distance, index))
            index += 1

    # due to max_ not always completely filled
    if limit > results.size():
        limit = results.size()

    if limit >= results.size():
        algorithm.sort(results.begin(), results.end(), ExtractDistanceComp())
    else:
        algorithm.partial_sort(results.begin(), results.begin() + <ptrdiff_t>limit, results.end(), ExtractDistanceComp())

    # copy elements into Python List
    result_list = PyList_New(<Py_ssize_t>limit)
    for i in range(limit):
        # PyList_SET_ITEM steals a reference
        # the casting is necessary to ensure that Cython doesn't
        # decref the result of Py_BuildValue
        # https://stackoverflow.com/questions/43553763/cythonize-list-of-all-splits-of-a-string/43557675#43557675
        # todo probably faster to create the tuple by hand

        PyList_SET_ITEM(result_list, <Py_ssize_t>i,
            <object>Py_BuildValue("Onn",
                <PyObject*>choices[results[i].index],
                results[i].distance,
                results[i].index))

    return result_list

cdef inline py_extract_dict(query, choices, scorer, processor, size_t limit, double score_cutoff, kwargs):
    cdef object score = None
    # todo working directly with a list is relatively slow
    # also it is not very memory efficient to allocate space for all elements even when only
    # a part is used. This should be optimised in the future
    cdef list result_list = []

    if processor is not None:
        for choice_key, choice in choices.items():
            if choice is None:
                continue

            score = scorer(query, processor(choice), score_cutoff, **kwargs)

            if score >= score_cutoff:
                result_list.append((choice, score, choice_key))
    else:
        for choice_key, choice in choices.items():
            if choice is None:
                continue

            score = scorer(query, choice, score_cutoff, **kwargs)

            if score >= score_cutoff:
                result_list.append((choice, score, choice_key))

    return heapq.nlargest(limit, result_list, key=lambda i: i[1])


cdef inline py_extract_list(query, choices, scorer, processor, size_t limit, double score_cutoff, kwargs):
    cdef object score = None
    # todo working directly with a list is relatively slow
    # also it is not very memory efficient to allocate space for all elements even when only
    # a part is used. This should be optimised in the future
    cdef list result_list = []
    cdef size_t index = 0

    if processor is not None:
        for choice in choices:
            if choice is None:
                index += 1
                continue

            score = scorer(query, processor(choice), score_cutoff, **kwargs)

            if score >= score_cutoff:
                result_list.append((choice, score, index))
            index += 1
    else:
        for choice in choices:
            if choice is None:
                index += 1
                continue

            score = scorer(query, choice, index, **kwargs)

            if score >= score_cutoff:
                result_list.append((choice, score, index))
            index += 1

    return heapq.nlargest(limit, result_list, key=lambda i: i[1])


def extract(query, choices, scorer=WRatio, processor=default_process, limit=5, double score_cutoff=0.0, **kwargs):
    """
    Find the best matches in a list of choices

    Parameters
    ----------
    query : str
        string we want to find
    choices : Iterable
        list of all strings the query should be compared with or dict with a mapping
        {<result>: <string to compare>}
    scorer : Callable, optional
        Optional callable that is used to calculate the matching score between
        the query and each choice. fuzz.WRatio is used by default
    processor : Callable, optional
        Optional callable that reformats the strings.
        utils.default_process is used by default, which lowercases the strings and trims whitespace
    limit : int
        maximum amount of results to return
    score_cutoff : float, optional
        Optional argument for a score threshold as a float between 0 and 100.
        Matches with a lower score than this number will be ignored. Default is 0,
        which deactivates this behaviour.
    **kwargs : Any, optional
        any other named parameters are passed to the scorer. This can be used to pass
        e.g. weights to string_metric.levenshtein

    Returns
    -------
    List[Tuple[str, Any, Any]]
        The return type is always a List of Tuples with 3 elements. However the values stored in the
        tuple depend on the types of the input arguments.

        * The first element is always the `choice`, which is the value thats compared to the query.

        * The second value represents the similarity calculated by the scorer. This can be:

          * An edit distance (distance is 0 for a perfect match and > 0 for non perfect matches).
            In this case only choices which have a `distance <= max` are returned.
            An example of a scorer with this behavior is `string_metric.levenshtein`.
          * A normalized edit distance (similarity is a score between 0 and 100, with 100 being a perfect match).
            In this case only choices which have a `similarity >= score_cutoff` are returned.
            An example of a scorer with this behavior is `string_metric.normalized_levenshtein`.

          Note, that for all scorers, which are not provided by RapidFuzz, only normalized edit distances are supported.

        * The third parameter depends on the type of the `choices` argument it is:

          * The `index of choice` when choices is a simple iterable like a list
          * The `key of choice` when choices is a mapping like a dict, or a pandas Series
        
        The list is sorted by `score_cutoff` or `max` depending on the scorer used. The first element in the list
        has the `highest similarity`/`smallest distance`.

    """
    cdef int def_process = 0
    cdef scorer_context ScorerContext
    cdef distance_context DistanceContext
    cdef size_t max_ = <size_t>-1

    if query is None:
        return None

    if limit is None or limit > len(choices):
        limit = len(choices)

    # preprocess the query
    if processor is default_process:
        def_process = 1
        # since this call is only performed once it is not very expensive to
        # make it in Python
        query = processor(query)
        processor = None
    elif callable(processor):
        query = processor(query)
    elif processor:
        def_process = 1
        # since this call is only performed once it is not very expensive to
        # make it in Python
        query = default_process(query)
        processor = None
    # query might be e.g. False
    else:
        processor = None

    # directly use the C++ implementation if possible
    ScorerContext = CachedScorerInit(scorer, query, def_process, kwargs)
    if ScorerContext.context != NULL:
        try:
            if hasattr(choices, "items"):
                return extract_dict(ScorerContext, choices, processor, limit, score_cutoff)
            else:
                return extract_list(ScorerContext, choices, processor, limit, score_cutoff)

        finally:
            # part of the context is dynamically allocated, so it has to be freed in any case
            ScorerContext.deinit(ScorerContext.context)

    # distance implemented in C++
    DistanceContext = CachedDistanceInit(scorer, query, def_process, kwargs)
    if DistanceContext.context != NULL:
        try:
            if hasattr(choices, "items"):
                return extract_distance_dict(DistanceContext, choices, processor, limit, max_)
            else:
                return extract_distance_list(DistanceContext, choices, processor, limit, max_)
        finally:
            # part of the context is dynamically allocated, so it has to be freed in any case
            DistanceContext.deinit(DistanceContext.context)

    # the scorer has to be called through Python
    if hasattr(choices, "items"):
        return py_extract_dict(query, choices, scorer, processor, limit, score_cutoff, kwargs)
    else:
        return py_extract_list(query, choices, scorer, processor, limit, score_cutoff, kwargs)


def __py_extract_iter_dict(query, choices, scorer, processor, double score_cutoff, kwargs):
    """
    implementation of extract_iter for:
      - type of choices = dict
      - scorer = python function
    """
    score = 0

    if processor is not None:
        for choice_key, choice in choices.items():
            if choice is None:
                continue

            score = scorer(query, processor(choice),
                processor=None, score_cutoff=score_cutoff, **kwargs)

            if score >= score_cutoff:
                yield (choice, score, choice_key)
    else:
        for choice_key, choice in choices.items():
            if choice is None:
                continue

            score = scorer(query, choice,
                processor=None, score_cutoff=score_cutoff, **kwargs)
    
            if score >= score_cutoff:
                yield (choice, score, choice_key)


def __py_extract_iter_list(query, choices, scorer, processor, double score_cutoff, kwargs):
    """
    implementation of extract_iter for:
      - type of choices = list
      - scorer = python function
    """
    cdef size_t index = 0
    score = 0

    if processor is not None:
        for choice in choices:
            if choice is None:
                index += 1
                continue
    
            score = scorer(query, processor(choice),
                processor=None, score_cutoff=score_cutoff, **kwargs)
    
            if score >= score_cutoff:
                yield(choice, score, index)
            index += 1
    else:
        for choice in choices:
            if choice is None:
                index += 1
                continue
    
            score = scorer(query, choice,
                processor=None, score_cutoff=score_cutoff, **kwargs)
    
            if score >= score_cutoff:
                yield(choice, score, index)
            index += 1


def extract_iter(query, choices, scorer=WRatio, processor=default_process, double score_cutoff=0.0, **kwargs):
    """
    Find the best match in a list of choices

    Parameters
    ----------
    query : str
        string we want to find
    choices : Iterable
        list of all strings the query should be compared with or dict with a mapping
        {<result>: <string to compare>}
    scorer : Callable, optional
        Optional callable that is used to calculate the matching score between
        the query and each choice. fuzz.WRatio is used by default
    processor : Callable, optional
        Optional callable that reformats the strings.
        utils.default_process is used by default, which lowercases the strings and trims whitespace
    score_cutoff : float, optional
        Optional argument for a score threshold as a float between 0 and 100.
        Matches with a lower score than this number will be ignored. Default is 0,
        which deactivates this behaviour.
    **kwargs : Any, optional
        any other named parameters are passed to the scorer. This can be used to pass
        e.g. weights to string_metric.levenshtein

    Yields
    -------
    Tuple[str, float, Any]
        Yields similarity between the query and each choice in form of a tuple.
        The Tuple will be in the form `(<choice>, <ratio>, <index of choice>)`
        when `choices` is a list of strings or `(<choice>, <ratio>, <key of choice>)`
        when `choices` is a mapping.
        Matches with a similarity, that is smaller than score_cutoff are skipped.
    """
    cdef int def_process = 0
    cdef scorer_context ScorerContext
    cdef distance_context DistanceContext
    cdef double score = 0.0
    cdef object py_score
    cdef size_t index
    cdef size_t distance

    cdef size_t max_ = <size_t>-1

    if query is None:
        return None

    # preprocess the query
    if processor is default_process:
        def_process = 1
        # since this call is only performed once it is not very expensive to
        # make it in Python
        query = processor(query)
        processor = None
    elif callable(processor):
        query = processor(query)
    elif processor:
        def_process = 1
        # since this call is only performed once it is not very expensive to
        # make it in Python
        query = default_process(query)
        processor = None
    # query might be e.g. False
    else:
        processor = None

    # directly use the C++ implementation if possible
    ScorerContext = CachedScorerInit(scorer, query, def_process, kwargs)
    if ScorerContext.context != NULL:
        try:
            if hasattr(choices, "items"):
                if processor is not None:
                    # c func + dict + python processor
                    for choice_key, choice in choices.items():
                        if choice is None:
                            continue

                        score = ScorerContext.scorer(ScorerContext.context, processor(choice), score_cutoff)

                        if score >= score_cutoff:
                            yield (choice, score, choice_key)
                else:
                    # c func + dict + no python processor
                    for choice_key, choice in choices.items():
                        if choice is None:
                            continue

                        score = ScorerContext.scorer(ScorerContext.context, choice, score_cutoff)

                        if score >= score_cutoff:
                            yield (choice, score, choice_key)
            else:
                index = 0
                if processor is not None:
                    # c func + list + python processor
                    for choice in choices:
                        if choice is None:
                            index += 1
                            continue

                        score = ScorerContext.scorer(ScorerContext.context, processor(choice), score_cutoff)

                        if score >= score_cutoff:
                            yield (choice, score, index)
                        index += 1
                else:
                    # c func + list + no python processor
                    for choice in choices:
                        if choice is None:
                            index += 1
                            continue

                        score = ScorerContext.scorer(ScorerContext.context, choice, score_cutoff)

                        if score >= score_cutoff:
                            yield (choice, score, index)
                        index += 1
        finally:
            # part of the context is dynamically allocated, so it has to be freed in any case
            ScorerContext.deinit(ScorerContext.context)
    
    else:
        # distance implemented in C++
        DistanceContext = CachedDistanceInit(scorer, query, def_process, kwargs)
        if DistanceContext.context != NULL:
            try:
                if hasattr(choices, "items"):
                    if processor is not None:
                        # c func + dict + python processor
                        for choice_key, choice in choices.items():
                            if choice is None:
                                continue
    
                            distance = DistanceContext.scorer(DistanceContext.context, processor(choice), max_)
    
                            if distance <= max_:
                                yield (choice, distance, choice_key)
                    else:
                        # c func + dict + no python processor
                        for choice_key, choice in choices.items():
                            if choice is None:
                                continue
    
                            distance = DistanceContext.scorer(DistanceContext.context, choice, max_)
    
                            if distance <= max_:
                                yield (choice, distance, choice_key)
                else:
                    index = 0
                    if processor is not None:
                        # c func + list + python processor
                        for choice in choices:
                            if choice is None:
                                index += 1
                                continue
    
                            distance = DistanceContext.scorer(DistanceContext.context, processor(choice), max_)
    
                            if distance <= max_:
                                yield (choice, distance, index)
                            index += 1
                    else:
                        # c func + list + no python processor
                        for choice in choices:
                            if choice is None:
                                index += 1
                                continue
    
                            distance = DistanceContext.scorer(DistanceContext.context, choice, max_)
    
                            if distance <= max_:
                                yield (choice, distance, index)
                            index += 1
            finally:
                # part of the context is dynamically allocated, so it has to be freed in any case
                DistanceContext.deinit(DistanceContext.context)

        # the scorer has to be called through Python
        else:
            if hasattr(choices, "items"):
                yield from __py_extract_iter_dict(query, choices, scorer, processor, score_cutoff, kwargs)
            else:
                yield from __py_extract_iter_list(query, choices, scorer, processor, score_cutoff, kwargs)